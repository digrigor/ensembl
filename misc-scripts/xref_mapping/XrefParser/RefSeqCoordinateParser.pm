=head1 LICENSE

Copyright [1999-2015] Wellcome Trust Sanger Institute and the EMBL-European Bioinformatics Institute
Copyright [2016-2019] EMBL-European Bioinformatics Institute

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

=cut

package XrefParser::RefSeqCoordinateParser;

use strict;
use warnings;
use Carp;
use DBI;
use Readonly;
use Bio::EnsEMBL::Registry;

use parent qw( XrefParser::BaseParser );
use Smart::Comments;


# Refseq sources to consider. Prefixes not in this list will be ignored
Readonly my $REFSEQ_SOURCES => {
    NM => 'RefSeq_mRNA',
    NR => 'RefSeq_ncRNA',
    XM => 'RefSeq_mRNA_predicted',
    XR => 'RefSeq_ncRNA_predicted',
    NP => 'RefSeq_peptide',
    XP => 'RefSeq_peptide_predicted',
};

# Only scores higher than the threshold will be stored for transcripts
Readonly my $TRANSCRIPT_SCORE_THRESHOLD => 0.75;

# Only scores higher than the threshold will be stored translateable transcripts
Readonly my $TL_TRANSCRIPT_SCORE_THRESHOLD => 0.75;

# If Biotypes do not match, score will be multiplied with the penalty
Readonly my $PENALTY => 0.9;

sub run_script {
  my ($self, $ref_arg) = @_;
### $self
### $ref_arg
  my $source_id    = $ref_arg->{source_id};
  my $species_id   = $ref_arg->{species_id};
  my $species_name = $ref_arg->{species};
  my $file         = $ref_arg->{file};
  my $db           = $ref_arg->{dba};
  my $dbi          = $ref_arg->{dbi} // $self->dbi;
  my $verbose      = $ref_arg->{verbose} // 0;

  # initial param validation step
  if((!defined $source_id) or (!defined $species_id) or (!defined $file) ){
    croak "Need to pass source_id, species_id and file as pairs";
  }

  my $file_params = $self->parse_file_string($file);

  # project or db param validation
  unless ( defined $db || ( ($file_params->{project} eq 'ensembl') || ($file_params->{project} eq 'ensemblgenomes') ) ) {
    croak "Missing or unsupported project value (supported values: ensembl, ensemblgenomes), or missing db value.";
  }

  # set default values
  $file_params->{user}   //= 'ensro';
  $file_params->{port}   //= '3306';
  $file_params->{ofuser} //= 'ensro';
  $file_params->{ofport} //= '3306';

  # get RefSeq source ids
  while (my ($source_prefix, $source_name) = each %{$REFSEQ_SOURCES}) {
    $self->{source_ids}->{$source_name} = $self->get_source_id_for_source_name( $source_name, 'otherfeatures' , $dbi )
  }

  if ($verbose) {
    for my $source_name (sort values %{$REFSEQ_SOURCES}) {
      print "$source_name source ID = $self->{source_ids}->{$source_name}\n";
    }
  }

  # get the species name
  my %id2name = $self->species_id2name($dbi);
  $species_name //= shift @{$id2name{$species_id}};

  # prepare registry and core/otherfeatures dba
  my $registry = "Bio::EnsEMBL::Registry";
  my ($core_dba, $otherf_dba);

  # for ensembl project, use provided connection details or default to staging
  if ( $file_params->{project} eq 'ensembl' ) {
    if (!defined $file_params->{host}) {
      $file_params->{host} = 'mysql-ens-sta-1';
      $file_params->{port} = '4519';
      $file_params->{user} = 'ensro';
    }
    $registry->load_registry_from_db(
      '-host' => $file_params->{host},
      '-port' => $file_params->{port},
      '-user' => $file_params->{user},
    );
    $core_dba = $registry->get_DBAdaptor($species_name, 'core');
    if (!defined $file_params->{ofhost}) {
      $file_params->{ofhost} = 'mysql-ens-sta-1';
      $file_params->{ofport} = '4519';
      $file_params->{ofuser} = 'ensro';
    }
    $registry->load_registry_from_db(
      '-host' => $file_params->{ofhost},
      '-port' => $file_params->{ofport},
      '-user' => $file_params->{ofuser},
    );
    $otherf_dba = $registry->get_DBAdaptor($species_name, 'otherfeatures');
    $otherf_dba->dnadb($core_dba);
  # for ensemblgenomes project, use staging and ignore any connection details provided
  } elsif ( $file_params->{project} eq 'ensemblgenomes' ) {
    $registry->load_registry_from_multiple_dbs( {
      '-host' => 'mysql-eg-staging-1.ebi.ac.uk',
      '-port' => '4160',
      '-user' => 'ensro',
    }, {
      '-host' => 'mysql-eg-staging-2.ebi.ac.uk',
      '-port' => '4275',
      '-user' => 'ensro',
    } );
    $core_dba = $registry->get_DBAdaptor($species_name, 'core');
    $otherf_dba = $registry->get_DBAdaptor($species_name, 'otherfeatures');
  # if no project but db provided, use that
  } else {
    $otherf_dba = $db;
    $core_dba = $db->dnadb();
  }

  # Not all species have an otherfeatures database, error if not found
  if (!$otherf_dba) {
    warn "No otherfeatures database found for species '$species_name'. Skipping\n";
    return;
  }

  # Cache EntrezGene IDs and source ID where available
  my $entrez_ids = $self->get_valid_codes("EntrezGene", $species_id, $dbi);
  $self->{source_ids}->{EntrezGene} = $self->get_source_id_for_source_name('EntrezGene', undef, $dbi);
  my $entrez_source_id = $self->get_source_id_for_source_name('EntrezGene', undef, $dbi);

  my $sa = $core_dba->get_SliceAdaptor();
  my $sa_of = $otherf_dba->get_SliceAdaptor();
  my $chromosomes_of = $sa_of->fetch_all('toplevel', undef, 1);

  # Fetch analysis object for refseq
  my $aa_of = $otherf_dba->get_AnalysisAdaptor();

  # Not all species have refseq_import data, exit if not found
  if (!defined $aa_of->fetch_by_logic_name('refseq_import')->logic_name) {
    warn "No data found for RefSeq_import. Skipping\n";
    return;
  }

  # Iterate over chromosomes in otherfeatures database
  foreach my $chromosome_of (@{$chromosomes_of}) {
    my $chr_name = $chromosome_of->seq_region_name();
    my $genes_of = $chromosome_of->get_all_Genes('refseq_import', undef, 1);

    # For each gene in that chromosome in otherfeatures database
    foreach my $gene_of (@{$genes_of}) {
      my $transcripts_of = $gene_of->get_all_Transcripts();

      # Create a range registry for all the exons of the refseq transcript
      foreach my $transcript_of (sort { $a->start <=> $b->start } @{$transcripts_of}) {
        my $id;
        # RefSeq accessions are now stored as xrefs rather than
        # stable ids as it used to be in the past. This means
        # priority is given to the display_id, and fall back to stable_id
        # for backwards compatibility.
        if (defined $transcript_of->display_xref ) {
          $id = $transcript_of->display_xref->display_id;
        } elsif (defined $transcript_of->stable_id) {
          $id = $transcript_of->stable_id;
        }
        # Skip non conventional and missing accessions
        unless ( exists $REFSEQ_SOURCES->{substr($id, 0, 2)} ) {
          print ">>> HERE!!!! $id\n";
          next;
        }

        my $transcript_result;
        my $tl_transcript_result;

        my $exons_of = $transcript_of->get_all_Exons();
        my $rr_exons_of = Bio::EnsEMBL::Mapper::RangeRegistry->new();
        my $tl_exons_of = $transcript_of->get_all_translateable_Exons();
        my $rr_tl_exons_of = Bio::EnsEMBL::Mapper::RangeRegistry->new();

        # register $exons_of on $rr_exons_of
        $self->compute_exons({
          exons              => $exons_of,
          check_and_register => $rr_exons_of
        });

        # register $tl_exons_of on $rr_tl_exons_of
        $self->compute_exons({
          exons              => $tl_exons_of,
          check_and_register => $rr_tl_exons_of
        });

        # Fetch slice in core database which overlaps refseq transcript
        my $chromosome = $sa->fetch_by_region('toplevel', $chr_name, $transcript_of->seq_region_start, $transcript_of->seq_region_end);
        my $transcripts = $chromosome->get_all_Transcripts(1);

        # Create a range registry for all the exons of the ensembl transcript
        foreach my $transcript(@{$transcripts}) {
          # make sure it's the same strand
          if ($transcript->strand != $transcript_of->strand) {
            next;
          }
          my $exons = $transcript->get_all_Exons();
          my $rr_exons = Bio::EnsEMBL::Mapper::RangeRegistry->new();
          my $tl_exons = $transcript->get_all_translateable_Exons();
          my $rr_tl_exons = Bio::EnsEMBL::Mapper::RangeRegistry->new();

          # register $exons on $rr_exons, overlap with $rr_exons_of
          my $exon_match = $self->compute_exons({
            exons              => $exons,
            check_and_register => $rr_exons,
            overlap            => $rr_exons_of
          });

          # register $tl_exons on $rr_tl_exons, overlap with $rr_tl_exons_of
          my $tl_exon_match = $self->compute_exons({
            exons              => $tl_exons,
            check_and_register => $rr_tl_exons,
            overlap            => $rr_tl_exons_of
          });

          # $exons_of overlap with $rr_exons
          my $exon_match_of = $self->compute_exons({
            exons   => $exons_of,
            overlap => $rr_exons
          });

          # $tl_exons_of overlap with $rr_tl_exons
          my $tl_exon_match_of = $self->compute_exons({
            exons   => $tl_exons_of,
            overlap => $rr_tl_exons
          });

          # Comparing exon matching with number of exons to give a score
          my $score = ( ($exon_match_of + $exon_match)) / (scalar(@{$exons_of}) + scalar(@{$exons}) );
          my $tl_score = 0;
          if (scalar(@{$tl_exons_of}) > 0) {
            $tl_score = ( ($tl_exon_match_of + $tl_exon_match)) / (scalar(@{$tl_exons_of}) + scalar(@{$tl_exons}) );
          }
          if ($transcript->biotype eq $transcript_of->biotype) {
            $transcript_result->{$transcript->stable_id} = $score;
            $tl_transcript_result->{$transcript->stable_id} = $tl_score;
          } else {
            $transcript_result->{$transcript->stable_id} = $score * $PENALTY;
            $tl_transcript_result->{$transcript->stable_id} = $tl_score * $PENALTY;
          }
        }

        my ($best_id, $best_score, $best_tl_score) = $self->compute_best_scores($transcript_result, $tl_transcript_result);

        # If a best match was defined for the refseq transcript, store it as direct xref for ensembl transcript
        if ($best_id) {
          my ($acc, $version) = split(/\./x, $id);

          my $source = $self->source_id_from_acc($acc);

          next unless defined $source;

          my $xref_id = $self->add_xref({
            acc        => $acc,
            version    => $version,
            label      => $id,
            desc       => undef,
            source_id  => $source,
            species_id => $species_id,
            dbi        => $dbi,
            info_type  => 'DIRECT'
          });
          $self->add_direct_xref($xref_id, $best_id, "Transcript", undef, $dbi);

          my $entrez_id = $gene_of->stable_id;
          my $tl_of = $transcript_of->translation();
          my $ta = $core_dba->get_TranscriptAdaptor();
          my $t = $ta->fetch_by_stable_id($best_id);
          my $tl = $t->translation();

          # Add link between Ensembl gene and EntrezGene
          if (defined $entrez_ids->{$entrez_id} ) {
            foreach my $dependent_xref_id (@{$entrez_ids->{$entrez_id}}) {
              $self->add_dependent_xref_maponly(
                $dependent_xref_id,
                $self->source_id_from_name('EntrezGene'),
                $xref_id,
                $source,
                $dbi
              );
              # $self->add_dependent_xref({
              #   master_xref_id => $xref_id,
              #   acc            => $dependent_xref_id,
              #   version        => $version,
              #   source_id      => $self->source_id_from_name('EntrezGene'),
              #   species_id     => $species_id,
              #   dbi            => $dbi
              # });
            }
          }

          # Also store refseq protein as direct xref for ensembl translation, if translation exists
          if (defined $tl && defined $tl_of) {
            if ($tl_of->seq eq $tl->seq) {
              my $tl_id = $tl_of->stable_id();
              my @xrefs = grep {$_->{dbname} eq 'GenBank'} @{$tl_of->get_all_DBEntries};
              if(scalar @xrefs == 1) {
                $tl_id = $xrefs[0]->primary_id();
              }
              my ($tl_acc, $tl_version) = split(/\./xms, $tl_id);

              my $tl_source = $self->source_id_from_acc($tl_acc);

              next unless defined $tl_source;

              my $tl_xref_id = $self->add_xref({
                acc        => $tl_acc,
                version    => $tl_version,
                label      => $tl_id,
                desc       => undef,
                source_id  => $tl_source,
                species_id => $species_id,
                dbi        => $dbi,
                info_type  => 'DIRECT'
              });
              $self->add_direct_xref($tl_xref_id, $tl->stable_id(), "Translation", undef, $dbi);
            }
          }
        }
      }
    }
  }
  return 0;
}



# parses the input string $file into an hash
# string $file is in the format as the example:
# script:project=>ensembl,host=>ens-staging1,dbname=>homo_sapiens_core_70_37,ofhost=>ens-staging1,...
# string until : is ignored, hash is built with keys=>values provided
sub parse_file_string {
  my ($self, $file_string) = @_;

  $file_string =~ s/\A\w+://x;

  my @param_pairs = split( /,/x, $file_string );

  my $params;

  # set provided values
  foreach my $pair ( @param_pairs ) {
    my ($key, $value) = split( /=>/x, $pair );
    $params->{$key} = $value;
  }

  return $params;
}

# params hash can provide 3 keyed params: exons, check_and_register and overlap
# exons is the array ref of the exons to process
# check_and_register may contain a range registry to check_and_register the exons there
# overlap may contain a range registry to calculate the overlap of the exons there
# returns the exon_match, which is always 0 if no overlap requested
sub compute_exons {
  my ($self, $params) = @_;

  my $exon_match = 0;

  foreach my $exon (@{$params->{exons}}) {
    if (defined $params->{check_and_register}) {
      $params->{check_and_register}->check_and_register( 'exon', $exon->seq_region_start, $exon->seq_region_end );
    }
    if (defined $params->{overlap}) {
      my $overlap = $params->{overlap}->overlap_size('exon', $exon->seq_region_start, $exon->seq_region_end);
      $exon_match += $overlap/($exon->seq_region_end - $exon->seq_region_start + 1);
    }
  }

  return $exon_match;
}

# requires transcript_result and tl_transcript_result hashrefs
# returns the best_id, best_score and best_tl_score
sub compute_best_scores {
  my ($self, $transcript_result, $tl_transcript_result) = @_;

  my $best_score = 0;
  my $best_tl_score = 0;
  my $best_id;

  # Comparing the scores based on coding exon overlap
  # If there is a stale mate, chose best exon overlap score
  foreach my $tid (sort { $transcript_result->{$b} <=> $transcript_result->{$a} } keys(%{$transcript_result})) {
    my $score = $transcript_result->{$tid};
    my $tl_score = $tl_transcript_result->{$tid};
    if ($score > $TRANSCRIPT_SCORE_THRESHOLD || $tl_score > $TL_TRANSCRIPT_SCORE_THRESHOLD) {
      if ($tl_score > $best_tl_score) {
        $best_id = $tid;
        $best_score = $score;
        $best_tl_score = $tl_score;
      } elsif ($tl_score == $best_tl_score) {
        if ($score > $best_score) {
          $best_id = $tid;
          $best_score = $score;
        }
      } elsif ($score >= $best_score) {
        $best_id = $tid;
        $best_score = $score;
      }
    }
  }

  return ($best_id, $best_score, $best_tl_score);
}

# returns the source id for a source name, requires $self->{source_ids} to have been populated
sub source_id_from_name {
  my ($self, $name) = @_;

  my $source_id;

  if ( exists $self->{source_ids}->{$name} ) {
    $source_id = $self->{source_ids}->{$name};
  } elsif ( $self->{verbose} ) {
    warn "WARNING: can't get source ID for name '$name'\n";
  }

  return $source_id;
}

# returns the source id for a RefSeq accession, requires $self->{source_ids} to have been populated
sub source_id_from_acc {
  my ($self, $acc) = @_;

  my $source_id;
  my $prefix = substr($acc, 0, 2);

  if ( exists $REFSEQ_SOURCES->{$prefix} ) {
    $source_id = $self->source_id_from_name( $REFSEQ_SOURCES->{$prefix} );
  } elsif ( $self->{verbose} ) {
    warn "WARNING: can't get source ID for accession '$acc'\n";
  }

  return $source_id;
}

1;
