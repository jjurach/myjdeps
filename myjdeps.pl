#!/usr/bin/perl -w
use strict;

use File::Temp qw(tempdir);

use vars qw(%KEYWORDS);
BEGIN {
  %KEYWORDS = map { $_=>1 } qw(public private protected void implements extends static);
}

sub main {
  my (@argv) = @_;

  $| = 1;
  my ($files,$args,$jarmap) = process_argv(@argv);

  my ($cmds) = commands_from_files($files,$args);

  my (@DATA, $cur);
  for my $cmd (@$cmds) {
    my $data = process_cmd($cmd);
    push @DATA, @$data;
  }

  display_data(\@DATA, $files, $jarmap);

  return 0;
}

sub process_argv {
  my (@argv) = @_;

  my (@files,@args,@jarmap);
  for my $arg (@argv) {
    if (! -f $arg) {
      push @args, $arg;
    } elsif ($arg =~ /.jar$/) {
      my $dir = tempdir("myjdepsXXXX", CLEANUP=>1, DIR=>$ENV{TMPDIR} || '/tmp');
      push @jarmap, sub { my ($s) = @_; $s =~ s/$dir\//$arg:/; return $s };
      system("(cd $dir; jar xv > list.txt) < $arg") == 0 or exit;
      open my $fh, '<', "$dir/list.txt" or die "open $dir/list.txt: $!\n";
      for my $line (<$fh>) {
        $line =~ /.* (\S+\.class)$/ and push @files, "$dir/$1";
      }
      close $fh;
    } else {
      push @files, $arg;
    }
  }
  return (\@files,\@args,\@jarmap);
}

sub commands_from_files {
  my ($files,$args) = @_;

  my @cmds;
  my @tfiles = @$files;
  while (@tfiles > 2000) {
    my @files0 = splice @tfiles, 0, 1000;
    push @cmds, "javap -p -c @$args @files0";
  }
  if (@tfiles > 1000) {
    my @files0 = splice @tfiles, 0, @tfiles/2;
    push @cmds, "javap -p -c @$args @files0";
  }
  push @cmds, "javap -p -c @$args @tfiles";

  return \@cmds;
}

sub display_data {
  my ($DATA,$files,$jarmap) = @_;

  if (@$files != @$DATA) {
    warn @$files." files but ".@$DATA." parses??\n";
  }

  print "digraph jdep {\nrankdir=LR\n" if $ENV{DOT};

  for my $data_n (0..$#$DATA) {
    my $data = $DATA->[$data_n];
    my $file = $files->[$data_n];
    for (@$jarmap) {
      $file = $_->($file);
    }
    my ($name,$seen,$error) = @{$data}{qw(name seen error)};

    my ($prim,$jlang,$java,$sun,$other) =
      partition([sort keys %$seen], qr!^\w+$!, qr!^java\.lang\.!, qr!^javax?\.!, qr!^sun\.!);

    print "# $file\n" if @$files == @$DATA;
    print("# Error: $error\n"), next if $error;

    print "$name\n" if ! $ENV{DOT};
    for my $list ($jlang,$java,$sun,$other) {
      for my $c (@$list) {
        print $ENV{DOT} ? "  \"$name\" -> \"$c\";\n" : "  $c\n";
      }
    }
  }
  print "}\n" if $ENV{DOT};
}

sub process_cmd {
  my ($cmd) = @_;

  my (@DATA, $cur);

  open my $fh, '-|', "$cmd 2>&1" or die "$cmd: $!\n";

  while (<$fh>) {
    s/\s+$//;
    if (/^Error:\s+(.*): (.*)$/) {
      push @DATA, ($cur = { compiled_from => $2, seen => {}, error => $1 });
      next;
    }
    if (/^Compiled from "(.*)"$/) {
      push @DATA, ($cur = { compiled_from => $1, seen => {} });
      next;
    }
    if (! $cur->{'name'}) {
      /^(.*)\b(class|interface) (.*){$/ or die "bad class $cur->{'compiled_from'} '$_'\n";
      my ($before, $type, $after) = ($1, $2, $3);
      $after =~ s/^(\S+) // or warn "No $type name? '$after'\n";
      $cur->{'name'} = $1;
      $cur->{'file_type'} = $type;
      for (scan_classes($after)) {
        $cur->{'seen'}->{$_}++ if length $_;
      }
    }
    
    if (/.*\/\/ class (.*)$/) {
      my $c = $1;
      next if $c eq '"[[Z"';
      next if $c eq '"[[I"';
      next if $c eq '"[Z"';
      next if $c eq '"[I"';
      $c =~ s!/!.!g;
      $cur->{seen}->{$c}++;
    } elsif (/.*\/\/ Field (.*?):L(.*);$/) {
      my $c = $2;
      $c =~ s!/!.!g;
      $cur->{seen}->{$c}++;
    } elsif (/^  (.*) (\w+)\((.*)\);$/) {
      my ($before, $after) = ($1, $3);
      for (scan_classes($before), scan_classes($after)) {
        $cur->{'seen'}->{$_}++ if length $_;
      }

    }
  }
  close $fh;
  return \@DATA;
}

sub scan_classes {
  my ($str) = @_;
  my %out;
  for my $c (grep { length $_ } split /[^\.\w]+/, $str) {
    $out{$c}++ if !$KEYWORDS{$c};
  }
  return sort keys %out;
}

sub partition {
  my ($list,@qr_list) = @_;
  my @out_list = map { [] } @qr_list, undef;
  ITEM: for my $item (@$list) {
    for (my $n=0; $n<@qr_list; $n++) {
      my $qr = $qr_list[$n];
      my $olist = $out_list[$n];
      if ($item =~ $qr) {
        push @$olist, $item;
        next ITEM;
      }
    }
    push @{$out_list[-1]}, $item;
  }
  return @out_list;
}

################################################################################
caller() or exit main(@ARGV);
