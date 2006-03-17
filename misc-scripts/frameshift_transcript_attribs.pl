use strict;
use warnings;

# Finds all potential frameshifts (exons 1, 2 4 or 5 bp apart)
# in a database and adds transcript attributes for them.
# Attribute value is intron length.

use Bio::EnsEMBL::DBSQL::DBAdaptor;
use Bio::EnsEMBL::Attribute;

use Getopt::Long;

my ($host, $port, $user, $pass, $dbpattern, $nostore, $delete, $locations);

GetOptions('host=s'      => \$host,
           'user=s'      => \$user,
           'port=i'      => \$port,
           'pass=s'      => \$pass,
           'dbpattern=s' => \$dbpattern,
	   'nostore'     => \$nostore,
	   'delete'      => \$delete,
	   'locations'   => \$locations,
           'help'        => sub { usage(); exit(0); });

$port ||= 3306;

usage() if(!$user || !$dbpattern || !$host);

my $dsn = "DBI:mysql:host=$host";
$dsn .= ";port=$port" if ($port);

my $db = DBI->connect($dsn, $user, $pass);

my @dbnames = map {$_->[0] } @{ $db->selectall_arrayref( "show databases" ) };

for my $dbname ( @dbnames ) {

  next if ($dbname !~ /$dbpattern/);

  print $dbname . "\n";

  my $db_adaptor = Bio::EnsEMBL::DBSQL::DBAdaptor->new(-host   => $host,
						       -user   => $user,
						       -pass   => $pass,
						       -dbname => $dbname,
						       -port   => $port);

  my $attribute_adaptor = $db_adaptor->get_AttributeAdaptor();
  my $transcript_adaptor = $db_adaptor->get_TranscriptAdaptor();

  if ($delete) {

    print STDERR "Deleting existing 'Frameshift' transcript attributes\n";
    my $dsth = $db_adaptor->dbc()->prepare("DELETE ta, at FROM transcript_attrib ta, attrib_type at WHERE at.attrib_type_id=ta.attrib_type_id AND at.code='Frameshift'");
    $dsth->execute();

  }

  my %biotypes = ();

  print STDERR "Finding frameshifts in $dbname, creating transcript attributes ...\n";
  print STDERR "Attributes will not be stored in database\n" if ($nostore);

  my $sth = $db_adaptor->dbc()->prepare
    (qq{SELECT t.transcript_id, g.biotype,
	MIN(IF(e1.seq_region_strand = 1,
	       e2.seq_region_start - e1.seq_region_end - 1,
	       e1.seq_region_start - e2.seq_region_end - 1)) AS intron_length,
	       ts.stable_id, e1.seq_region_end, e2.seq_region_start, e1.seq_region_strand, s.name
	FROM exon e1, exon e2, exon_transcript et1, exon_transcript et2,
	transcript t, gene g, transcript_stable_id ts, seq_region s
	WHERE et1.exon_id = e1.exon_id
	AND et2.exon_id = e2.exon_id
	AND et1.transcript_id = et2.transcript_id
	AND et1.rank = et2.rank - 1
	AND et1.transcript_id = t.transcript_id
	AND t.gene_id = g.gene_id
	AND t.transcript_id = ts.transcript_id
        AND s.seq_region_id=g.seq_region_id
	GROUP BY t.transcript_id
	HAVING intron_length IN (1,2,4,5)});

  $sth->execute();

  my ($transcript_id, $biotype, $intron_length, $stable_id, $start, $end, $strand, $count, $seq_region_name);
  $sth->bind_columns(\$transcript_id, \$biotype, \$intron_length, \$stable_id, \$start, \$end, \$strand, \$seq_region_name);

  while ($sth->fetch()) {

    my $attribute = Bio::EnsEMBL::Attribute->new(-CODE => 'Frameshift',
						 -NAME => 'Frameshift',
						 -DESCRIPTION => 'Frameshift modelled as intron',
						 -VALUE => $intron_length);

    my @attribs = ($attribute);

    my $transcript = $transcript_adaptor->fetch_by_dbID($transcript_id);

    $attribute_adaptor->store_on_Transcript($transcript, \@attribs) if (!$nostore);

    print join("\t", $stable_id, $start, $end, $strand, $intron_length, $seq_region_name, "\n") if ($locations);

    $biotypes{$biotype}++;
    $count++;

  }

  if ($count) {

    print "$count short intron attributes\n";
    print "Attributes not stored in database\n" if ($nostore);

    print "Biotypes of affected genes:\n";
    foreach $biotype (keys %biotypes) {
      print $biotype . "\t" . $biotypes{$biotype} . "\n";
    }

    print "\n";

  } else {

    print "No frameshift introns found!\n";

  }

}

# ----------------------------------------------------------------------

sub usage {

  print << "EOF";

  Finds all potential frameshifts (exons 1, 2 4 or 5 bp apart) in a database 
  and adds transcript  attributes for them. Attribute value is intron length.

  perl introns_to_transcript_attribs.pl {options}

 Options ([..] indicates optional):

   --host       The database server to connect to.

   [--port]     The port to use. Defaults to 3306.

   --user       Database username. Must allow writing.

   --pass       Password for user.

   --dbpattern  Regular expression to define which databases are affected.

  [--nostore]   Don't store the attributes, just print results.

  [--delete]    Delete any existing "Frameshift" attributes before creating new ones.

  [--locations] Print the start, end and strand of the introns.

  [--help]      This text.


EOF

}

# ----------------------------------------------------------------------
