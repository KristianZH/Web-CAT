#!c:\perl\bin\perl.exe -w
#=============================================================================
#   @(#)$Id: execute.pl,v 1.1 2008/10/11 01:02:23 stedwar2 Exp $
#-----------------------------------------------------------------------------
#   DownloadBatchPlugin
#
#   usage:
#       execute.pl <properties-file>
#=============================================================================
use strict;

#use Archive::Zip;
use File::Basename;
use File::stat;
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

my $pid         = $cfg->getProperty('userName');
my $workingDir	= $cfg->getProperty('workingDir');
my $pluginHome	= $cfg->getProperty('pluginHome');
my $resultDir	= $cfg->getProperty('resultDir');


#-------------------------------------------------------
# In addition, some local definitions within this script
#-------------------------------------------------------
my $debug       = $cfg->getProperty('debug', 0);

#-----------------------------
my $version     = "1.0.0";

die "ANT_HOME environment variable is not set! (Should come from ANTForPlugins)"
    if !defined($ENV{ANT_HOME});
$ENV{PATH} =
    "$ENV{ANT_HOME}" . $Web_CAT::Utilities::FILE_SEPARATOR . "bin"
    . $Web_CAT::Utilities::PATH_SEPARATOR . $ENV{PATH};

my $ANT                 = "ant";


#-----------------------------------------------------------------------------
sub handle_start
{
    return 'reallyStart';
}


#-----------------------------------------------------------------------------
sub handle_reallyStart
{
    return 'item:almostFinish';
}


#-----------------------------------------------------------------------------
sub handle_almostFinish
{
    $batcher->updateProgress(1, "Finishing ...");

    return 'finish';
}


#-----------------------------------------------------------------------------
sub handle_finish
{
    $batcher->updateProgress(1, "Finishing ...");

    my $zipName = $cfg->getProperty('download.zip.name', '');

    my $numReports = $cfg->getProperty("numReports", 0);
    $numReports++;
    $cfg->setProperty("report$numReports.file", "feedback.html");
    $cfg->setProperty("report$numReports.mimeType", "text/html");
    $cfg->setProperty("numReports", $numReports);

    open SAMPLE_REPORT, ">$resultDir/feedback.html";
    if ($zipName eq '')
    {
        $cfg->setProperty(
            "report$numReports.title", "No Submissions to Download");
        print SAMPLE_REPORT "<p>No matching submissions were found.</p>\n";
    }
    else
    {
        $cfg->setProperty("report$numReports.title", "Your Download Is Ready");
        print SAMPLE_REPORT "<p>Downloadable zip archive of requested ",
            "assignment submissions: <a href=\"$zipName\">$zipName</a></p>\n";
    }
    close SAMPLE_REPORT;

    return 'end';
}


#-----------------------------------------------------------------------------
sub assignmentDirName
{
    my $assignment = shift || 'submissions';

    $assignment =~ s/\s/-/g;
    $assignment =~ s/[^A-Za-z0-9_\.-]//g;
    return $assignment;
}


#-----------------------------------------------------------------------------
sub zipFileName
{
    my $assignment = shift || 'submissions';

    my $newName = $assignment . '.zip';
    my $oldName = $cfg->getProperty('download.zip.name', $newName);
    if ($oldName ne $newName)
    {
        $newName = 'submissions.zip';
    }
    $cfg->setProperty('download.zip.name', $newName);
    return "$resultDir/$newName";
}


#-----------------------------------------------------------------------------
sub handle_item
{
    my $submissionProps = Config::Properties::Simple->new(
        file => $cfg->getProperty('gradingPropertiesPath'));
    my $student = $submissionProps->getProperty('userName');

    my $progress = $batcher->iterationProgress();
    $batcher->updateProgress(
        $progress, "Processing submission from $student ...");

    my $assignment = assignmentDirName(
        $submissionProps->getProperty('assignment', 'submissions'));
    my $zipFile = zipFileName($assignment);

    my $studentFile = $cfg->getProperty('submissionPath');

#    my $zip = Archive::Zip->new();
#    if (-f $zipFile)
#    {
#        if ($zip->read($zipFile) != Archive::Zip::AZ_OK)
#        {
#            die "Cannot create or read from '$zipFile': $!";
#        }
#    }

    my $memberName = $submissionProps->getProperty('CRN') . '/'
        . $assignment . '/'
        . $student . '/'
        . $submissionProps->getProperty('submissionNo') . '/'
        . basename($studentFile);

    my $cmdline = $Web_CAT::Utilities::SHELL
        . "$ANT -f \"$pluginHome/antzip.xml\" "
        . "\"-Dbasedir=$workingDir\" "
        . "\"-Dzip.file=$zipFile\" "
        . "\"-Dsource.file.name=$studentFile\" "
        . "\"-Ddest.file.name=$memberName\" "
        . "2>&1 >>  \"$resultDir"
        . $Web_CAT::Utilities::FILE_SEPARATOR
        . "ant.log\"";
        #. "2>&1 > " . File::Spec->devnull;

    print STDERR "command = $cmdline\n" if ($debug);
    system($cmdline);

#    if (!defined $zip->memberNamed($memberName))
#    {
        print STDERR "adding $studentFile\n" if ($debug);
#        $zip->addFile($studentFile, $memberName);
#        if ($zip->overwriteAs($zipFile) != Archive::Zip::AZ_OK)
#        {
#            die "Unable to write to zip file $studentFile: $!";
#        }
#    }

    return 'continue';
}


#-----------------------------------------------------------------------------
# main loop

$batcher->run();


#-----------------------------------------------------------------------------
exit(0);
