#!/usr/bin/perl
use strict;
use List::Util qw(shuffle);
use Getopt::Long;

##Please specify where your prefered database searching tool locates
##NCBI blast ftp://ftp.ncbi.nlm.nih.gov/blast/executables/legacy.NOTSUPPORTED/2.2.26/blast-2.2.26-x64-linux.tar.gz
my $blast    = "blastall";
my $formatdb = "formatdb";
my $blast_parameters="-m 8 -e 1e-4 -b 1 -v 1";
##diamond https://github.com/bbuchfink/diamond/releases
my $diamond = "diamond";
my $diamond_parameters="-k 1 -e 1e-4 -p 20";
##usearch https://www.drive5.com/usearch/download.html
my $usearch = "usearch8.1.1861_i86linux32";
my $usearch_parameters="-id 0.3";

my ( $workdir, $method, $outfile, $seqtype, $filetype, $sampleinfo, $randomsampling );
GetOptions(
  "d=s" => \$workdir,    ##set directory for sequence file location
  "m=s" => \$method,
  "f=s" => \$filetype,    ##file type, including fastq, fastq.gz, fasta,fasta.gz, fq, fq.gz, fa, fa.gz
  "s=s"  => \$seqtype,           ##prot, nucl
  "si=s" => \$sampleinfo,        ##information file for sequence numbers in each sample
  "rs=s" => \$randomsampling,    ##random sampling size, by default the minimum is used
  "o=s"  => \$outfile            ##out file for functional profiles
);
if ( !defined $workdir
  || !defined $method
  || !defined $filetype
  || !defined $outfile
  || !defined $seqtype
  || !defined $sampleinfo
  || $method !~ /^diamond|usearch|blast$/
  || $filetype !~ /^fastq|fastq.gz|fasta|fasta.gz|fq|fq.gz|fa|fa.gz$/ )
{
  &PrintHelp();
  die;
}

my (@files);
if ( $method eq "diamond" ) {
  @files = glob("$workdir/*$filetype");
  my $diamond_db = "$diamond makedb --in ./SCycDB_2020Mar --db ./SCycDB_2020Mar";
  system("$diamond_db");
  foreach my $file (@files) {
    my $out = $file;
    $out =~ s/$filetype/diamond/;
    system("$diamond blastx $diamond_parameters -d ./SCycDB_2020Mar.dmnd -q $file -o $out")
      if $seqtype eq "nucl";
    system("$diamond blastp $diamond_parameters -d ./SCycDB_2020Mar.dmnd -q $file -o $out")
      if $seqtype eq "prot";
    system("cp $out ./");
  }
}
elsif ( $method eq "usearch" ) {
  die "Please specify the location of usearch!" if !-e $usearch;
  if ( $filetype =~ /gz/ ) {
    die "Only fastq and fasta files are supported by usearch!\n";
  }
  @files = glob("$workdir/*$filetype");
  foreach my $file (@files) {
    my $out = $file;
    $out =~ s/$filetype/usearch/;
    system("$usearch -usearch_global $file -db ./SCycDB_2020Mar $usearch_parameters -blast6out $out");
    system("cp $out ./");
  }
}
elsif ( $method eq "blast" ) {
  die "Please specify the location of blast and/or formatdb!" if !-e $blast or !-e $formatdb;
  if ( $filetype =~ /gz|fastq/ ) {
    die "Only fasta files are supported by blast program!";
  }
  @files = glob("$workdir/*$filetype");
  system("$formatdb -i ./SCycDB_2020Mar -p T");
  foreach my $file (@files) {
    my $out = $file;
    $out =~ s/$filetype/blast/;
    system("blastall -p blastp -d ./SCycDB_2020Mar -i $file -o $out $blast_parameters")
      if $seqtype eq "prot";
    system("blastall -p blastx -d ./SCycDB_2020Mar -i $file -o $out $blast_parameters")
      if $seqtype eq "nucl";
    system("cp $out ./");
  }
}

my %id2gene;
open( FILE, "./id2gene.2020Mar.map" ) || die "#1 cannot open id2gene.2020Mar.map\n";
while (<FILE>) {
  chomp;
  my @items = split( "\t", $_ );
  $id2gene{ $items[0] } = $items[1];
}
close FILE;

my %abundance;
my %samples;
my @sfiles=glob("*diamond") if $method eq "diamond";
@sfiles=glob("*usearch") if $method eq "usearch";
@sfiles=glob("*blast") if $method eq "blast";
die "No diamond/usearch/blast files were detected!\n" if $#sfiles==-1;
foreach my $file ( @sfiles ) {
  $file =~ /(.*?)\.$method/;
  my $sample = $1;
  $samples{$sample} = 1;
  my %hit;
  open( FILE, "$file" ) || die "#2 cannot open $file\n";
  while (<FILE>) {
    chomp;
    my @items = split( "\t", $_ );
    my $gene = $id2gene{ $items[1] };
    if ( !$hit{ $items[0] } ) {
      $abundance{$sample}{$gene}++ if $gene;
      $hit{ $items[0] } = 1;
    }
  }
  close FILE;
}

my %size;
my @sizes;
open( FILE, "$sampleinfo" ) || die "#3 cannot open $sampleinfo\n";
while (<FILE>) {
  chomp;
  my @items = split( "\t", $_ );
  $size{ $items[0] } = $items[1];
  push( @sizes, $items[1] );
}
close FILE;
foreach my $sample(keys %samples){
  die "$sample was not found in $sampleinfo, please check!\n" if !$size{$sample};
}

@sizes = sort { $a <=> $b } @sizes;
my $rs = $sizes[0] if !defined $randomsampling;
$rs = $randomsampling if defined $randomsampling;
my %abundance_rs = &RandomSampling( \%abundance, \%size, $rs );

my @samples = keys %samples;
open( OUT, ">$outfile" ) || die "#4 cannot write $outfile\n";
print OUT "#random sampling: $rs\n";
print OUT "Gene\t", join( "\t", @samples ), "\n";
foreach my $gene ( sort keys %abundance_rs ) {
  print OUT "$gene";
  foreach my $sample (@samples) {
    print OUT "\t$abundance_rs{$gene}{$sample}" if $abundance_rs{$gene}{$sample};
    print OUT "\t0"                             if !$abundance_rs{$gene}{$sample};
  }
  print OUT "\n";
}
close OUT;

sub RandomSampling() {
  my ( $abundance, $size, $rs ) = @_;
  my %abundance = %$abundance;
  my %size      = %$size;
  my %sum;
  foreach my $sample ( keys %abundance ) {
    foreach my $gene ( keys %{ $abundance{$sample} } ) {
      $sum{$sample} += $abundance{$sample}{$gene};
    }
  }
  my %abundance_rs;
  foreach my $sample ( keys %size ) {
    my @array = shuffle( 1 .. $size{$sample} );
    @array = @array[ 0 .. $rs - 1 ];
    @array = grep { $_ <= $sum{$sample} } @array;
    my $i = 1;
    foreach my $gene ( keys %{ $abundance{$sample} } ) {
      my @tmp = grep { $_ >= $i && $_ <= ( $abundance{$sample}{$gene} + $i - 1 ) } @array;
      $abundance_rs{$gene}{$sample} = @tmp;
      $i += $abundance{$sample}{$gene};
    }
  }
  return %abundance_rs;
}

sub PrintHelp() {
  print "Incorrect parameters!\n";
  print
    "perl SCycDB_FunctionProfiler.PL -d <workdir> -m <diamond|usearch|blast> -f <filetype> -s <seqtype> -si <sample size info file> -rs <random sampling size> -o <outfile>\n";
  print "-m diamond|usearch|blast\n";
  print "-f fastq, fastq.gz, fasta,fasta.gz, fq, fq.gz, fa, fa.gz\n";
  print "-s sequence type, nucl or prot \n";
  print "-si tab delimited file for sequence number in each file\n";
  print "-rs random sampling size\n";
}
