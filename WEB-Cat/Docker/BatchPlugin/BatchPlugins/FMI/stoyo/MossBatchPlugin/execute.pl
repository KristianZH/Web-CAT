#!c:\perl\bin\perl.exe -w
#=============================================================================
#   @(#)$Id: execute.pl,v 1.1 2008/10/11 01:02:23 stedwar2 Exp $
#-----------------------------------------------------------------------------
#   MossBatchPlugin
#
#   usage:
#       execute.pl <properties-file>
#=============================================================================
use strict;
use IO::Socket;
use File::Find;
use File::Path;
# STOYO added next line:
use URI::Escape;
use Config::Properties::Simple;
use Web_CAT::Batcher;
use Web_CAT::Utilities
    qw( confirmExists filePattern copyHere htmlEscape addReportFile scanTo
        scanThrough linesFromFile );

#=============================================================================
# Bring command line args into local variables for easy reference
#=============================================================================
my %state_map = (
    'start'        => \&handle_start,
    'reallyStart'  => \&handle_reallyStart,
    'item'         => \&handle_item,
    'almostFinish' => \&handle_almostFinish,
    'finish'       => \&handle_finish,
);

my $propfile    = $ARGV[0];	# property file name

my $batcher     = Web_CAT::Batcher->new($propfile, \%state_map);
my $cfg         = $batcher->properties();
my $sock        = undef;

my $pid         = $cfg->getProperty('userName');
my $working_dir	= $cfg->getProperty('workingDir');
my $script_home	= $cfg->getProperty('scriptHome');
my $log_dir	    = $cfg->getProperty('resultDir');

my $outfile = $log_dir . '/outfile.txt';

# These are for sending data to MOSS; the opt_* are for command-line options
#   (see mossnet.pl script for more details)
my $server = 'moss.stanford.edu';
my $port = '7690';
my $setid = 1;
my $user_count = 0;
my $results_url = "";
my $opt_l = $cfg->getProperty('language', 'java');
$opt_l =~ tr/A-Z/a-z/;
if ($opt_l eq 'c++')
{
    $opt_l = 'cc';
}
my $opt_m = $cfg->getProperty('maxmatches', 10);
my $opt_d = 1;
my $opt_x = 0;
{
    my $experimental = $cfg->getProperty('experimental');
    if (defined $experimental && $experimental =~ m/^(true|yes|1|on)$/i)
    {
        $opt_x = 1;
    }
}

my $opt_c = "";
my $opt_n =  $cfg->getProperty('pairs', 250);
my $userid = $cfg->getProperty('mossUserToken');

# These are for storing files found by wanted* callback functions
my $jarFiles = "";
my $zipFiles = "";
my @sourceFiles = ();

# A callback function to be passed to find().
sub wantedSource
{
    my $currentFile = $_;

    if ($currentFile !~ /^\./o
        && $currentFile =~ /.+\.(java|cc|cpp|c|h|pas|scm|rkt|scheme|pro|pl|prolog|h|hxx|cxx|hpp|py|rb)$/io
        && ! -d $currentFile)
    {
        # STOYO added next line: uri_escape
        $currentFile = uri_escape($currentFile);
        push(@sourceFiles, $File::Find::dir . '/' . $currentFile);
    }
}

#-------------------------------------------------------
# In addition, some local definitions within this script
#-------------------------------------------------------
my $debug                    = $cfg->getProperty('debug', 0);

#-----------------------------
my $version                  = "1.0.0";


#-----------------------------------------------------------------------------
sub handle_start
{
    $batcher->updateProgress(0.05, "Connecting to MOSS server ...");

    $cfg = $batcher->properties();

    open (OUTFILE, ">>$outfile");
#    print OUTFILE "start called\n";

    print OUTFILE "Establishing socket to $server port $port\n";

    $sock = new IO::Socket::INET(
        PeerAddr => $server, PeerPort => $port, Proto => 'tcp');
    # What's the best way to handle socket errors here?
    #die "Could not connect to server $server: $!\n" unless $sock;
    $sock->autoflush(1);

#    print OUTFILE "Socket established; authenticating\n";

    print $sock "moss $userid\n";      # authenticate user
    print $sock "directory $opt_d\n";
    print $sock "X $opt_x\n";
    print $sock "maxmatches $opt_m\n";
    print $sock "show $opt_n\n";

    # We ned to use the appropriate code for the language used...

    print $sock "language $opt_l\n";
    my $msg = <$sock>;
    chop($msg);
    if ($msg eq "no")
    {
        print $sock "end\n";
        print OUTFILE "Unrecognized language $opt_l\n";
        die "Unrecognized language $opt_l.";
    }
    else
    {
        print OUTFILE "Authenticated, and batch information sent\n";
    }

#    print OUTFILE "start done\n";
    close (OUTFILE);

    # We should return an error code, if possible for:
    #   failure to establish a socket
    #   incorrect language code
    #   what if an incorrect auth token is used?

    return 'reallyStart';
}


#-----------------------------------------------------------------------------
sub handle_reallyStart
{
    $batcher->updateProgress(0.10, "Connected ...");

    $cfg = $batcher->properties();

#    open (OUTFILE, ">>$outfile");
#    print OUTFILE "reallyStart called\n";

#    print OUTFILE "Uploading base files\n";

    # upload any base files
    #$i = 0;
    #while($i < $bindex) {
    #    &upload_file($opt_b[$i++],0,$opt_l);
    #}

    # This counter gets incremented for eack call to handle_item
    #my $setid = 1;

#    print OUTFILE "reallyStart done\n";
#    close (OUTFILE);

    return 'item:almostFinish';
}


#-----------------------------------------------------------------------------
sub handle_almostFinish
{
    $batcher->updateProgress(0.95, "Waiting for MOSS response ...");

    $cfg = $batcher->properties();

    open (OUTFILE, ">>$outfile");
 #   print OUTFILE "almostFinish called\n";

    print $sock "query 0 $opt_c\n";

    print OUTFILE "Query submitted.  Waiting for the server's response.\n";

    $results_url = <$sock>;
    print OUTFILE "$results_url\n";

#    print OUTFILE "almostFinish done\n";
    close (OUTFILE);

    return 'finish';
}


#-----------------------------------------------------------------------------
sub handle_finish
{
    $batcher->updateProgress(1, "Finished.");

    $cfg = $batcher->properties();

#    open (OUTFILE, ">>$outfile");
#    print OUTFILE "finish called\n";
#    close (OUTFILE);
#    my @lines = linesFromFile("$outfile");

    open REPORT, ">$log_dir/feedback.html";
#    print REPORT "<h1>A big ol' header</h1>\n";
#    print REPORT "<a href='batch.properties'>A link</a>\n";

    my ($day, $mon, $year) = (localtime(time + 60*60*24*14))[3..5];
    my @abbr = qw( Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec );

    print REPORT "<p>View the <a href=\"$results_url\" target=\"_blank\">MOSS "
        . 'Results</a> on the MOSS server (retained until '
        . "$abbr[$mon] $day, " . (1900 + $year) . ').</p>';

#    print REPORT "<pre>\n";
#    foreach (@lines)
#    {
#        print REPORT $_;
#    }
#    print REPORT "</pre>\n";
#    close REPORT;

    my $numReports = $cfg->getProperty("numReports", 0);
    $numReports++;
    $cfg->setProperty("report$numReports.file", "feedback.html");
    $cfg->setProperty("report$numReports.mimeType", "text/html");
    $cfg->setProperty("report$numReports.title", "Moss Results");
    $cfg->setProperty("numReports", $numReports);

    return 'end';
}


sub upload_file {
    my ($file, $id, $lang, $prefix) = @_;
##
## The stat function does not seem to give correct filesizes on windows, so
## we compute the size here via brute force.
##
#    open(F, $file);
#    my $size = 0;
#    while (<F>)
#    {
#        $size += length($_);
#    }
#    close(F);

    # STOYO added next line:
    # $file = uri_escape($file);
    my $size = (stat($file))[7];

    # STOYO: added next line:
    # $file = uri_unescape($file);

    my $mossFileName = $file;
    $mossFileName =~ s/^\E$prefix\Q//;
    $mossFileName =~ s/[\s\"\'&<>]/-/ig;
    # print OUTFILE "Uploading $file ...";
    print $sock "file $id $lang $size $mossFileName\n";
    open(F,$file);
    while (<F>)
    {
        print $sock $_;
    }
    close(F);
    # print OUTFILE "done.\n";
}


#-----------------------------------------------------------------------------
sub handle_item
{
    $cfg = $batcher->properties();

    my $progress = $batcher->iterationProgress();


    open (OUTFILE, ">>$outfile");
#    print OUTFILE "item called: $progress -- $propfile\n";

    # Determine the path to the submission being scanned
    #   (Note that we may only want to use the last submission - how
    #    would the script or the batching infrastructure handle this?)

    my $submissionPath = $cfg->getProperty('submissionPath');
    my $resultDir = $cfg->getProperty('resultDir');
    my $pluginHome = $cfg->getProperty('pluginHome');
    $user_count++;
    my $userName =
        $cfg->getProperty('submissionUserName', 'user' . $user_count);
    my $outputDir = "$resultDir/unpack/$userName";
    rmtree($outputDir, 0, 1);

    $batcher->updateProgress(0.10 + $progress * 0.80,
        "Uploading file(s) for '$userName' ...");

    print OUTFILE "submission path = $submissionPath \n";

    @sourceFiles = ();

    if ($submissionPath =~ /.+\.(zip|jar)$/io)
    {
        system("ant -Dzip.src=$submissionPath -Dzip.dest=$outputDir "
            . "-q -l $resultDir/ant.log "
            . "-f $pluginHome/antzip.xml");

        # Upload all of the source (.java) files that were in the archive
        find(\&wantedSource, $outputDir);
    }
    else
    {
        @sourceFiles = ($submissionPath);
    }

    foreach (@sourceFiles)
    {
        print OUTFILE "    file: $_\n";
        upload_file("$_", $setid++, $opt_l, "$resultDir/unpack/");
    }

    # Clean up
    rmtree($outputDir, 0, 1);

#    print OUTFILE "item done\n";
    close (OUTFILE);

    return 'continue';
}


#-----------------------------------------------------------------------------
# main loop

$batcher->run();

#-----------------------------------------------------------------------------
exit(0);
