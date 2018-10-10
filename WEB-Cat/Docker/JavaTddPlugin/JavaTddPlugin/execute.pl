#!/usr/bin/perl
#=============================================================================
#   Web-CAT: execute script for Java submissions
#
#   usage:
#       execute.pl <properties-file>
#=============================================================================

use Class::Struct;
use strict;
use Carp qw(carp croak);
use Config::Properties::Simple;
use File::Basename;
use File::Copy;
use File::Spec;
use File::stat;
use File::Glob qw (bsd_glob);
use Proc::Background;
use Web_CAT::Beautifier;
use Web_CAT::Clover::Reformatter;
use Web_CAT::FeedbackGenerator;
use Web_CAT::JUnitResultsReader;
use XML::Smart;
use Data::Dump qw(dump);


#=============================================================================
# Load properties files given on command line
#=============================================================================
my $propfile   = $ARGV[0];     # property file name
my $cfg        = Config::Properties::Simple->new(file => $propfile);

my $pluginHome = $cfg->getProperty('pluginHome');
{
    # scriptHome is deprecated, but may still be used on older servers
    if (! defined $pluginHome)
    {
        $pluginHome = $cfg->getProperty('scriptHome');
    }
}


#=============================================================================
# Import local libs
#=============================================================================

use lib dirname(__FILE__) . '/perllib';
use JavaTddPlugin;
use Web_CAT::Utilities qw(
    confirmExists
    filePattern
    copyHere
    htmlEscape
    addReportFile
    scanTo
    scanThrough
    linesFromFile
    addReportFileWithStyle
    );
use Web_CAT::ExpandedFeedbackUtil qw(
    extractAboveBelowLinesOfCode
    checkForPatternInFile
    negateValueZeroToOneAndOneToZero
    extractLineOfCode
    );
use Web_CAT::ErrorMapper qw(
    compilerErrorHintKey
    runtimeErrorHintKey
    compilerErrorEnhancedMessage
    setResultDir
    codingStyleMessageValue
    );


#=============================================================================
# Bring config properties into local variables for easy reference
#=============================================================================

my $pid        = $cfg->getProperty('userName');
my $workingDir = $cfg->getProperty('workingDir');
my $resultDir  = $cfg->getProperty('resultDir');

#Using ResultDir in ErrorMapper file and we set the value here
setResultDir($resultDir);

my $useEnhancedFeedback = $cfg->getProperty('useEnhancedFeedback', 0);
$useEnhancedFeedback = ($useEnhancedFeedback =~ m/^(true|on|yes|y|1)$/i);

my @beautifierIgnoreFiles = ();
my $timeout    = $cfg->getProperty('timeout', 45);
my $publicDir  = "$resultDir/public";

my $maxToolScore          = $cfg->getProperty('max.score.tools', 20);
my $maxCorrectnessScore   = $cfg->getProperty('max.score.correctness',
                                              100 - $maxToolScore);

#my $instructorCases        = 0;
#my $instructorCasesPassed  = undef;
my $instructorCasesPercent = 0;
my $studentCasesPercent    = 0;
my $codeCoveragePercent    = 0;
#my $studentTestMsgs;
my $hasJUnitErrors         = 0;

my %status = (
    'antTimeout'         => 0,
    'studentHasSrcs'     => 0,
    'studentTestResults' => undef,
    'instrTestResults'   => undef,
    'toolDeductions'     => 0,
    'compileMsgs'        => "",
    'compileErrs'        => 0,
    'feedback'           =>
        new Web_CAT::FeedbackGenerator($resultDir, 'feedback.html'),
    'instrFeedback'      =>
        new Web_CAT::FeedbackGenerator($resultDir, 'staffFeedback.html')
);

# To mark components in each module(in WebCat-java submission) based on
# whether all the errors of a subsection are passed or not. For instance,
# "1" in compilerErrors implies: no compilerErrors

# If there are no compiler errors or warnings or signature errors then
# firstHalfRadialBar = 50; otherwise zero. Likewise secondHalfRadialBar
# corresponds to codingFlaws and junitTests

my %codingSectionStatus = (
    'compilerErrors'            => 1,
    'compilerWarnings'          => 1,
    'signatureErrors'           => 1,
    'codingFlaws'               => 1,
    'junitTests'                => 1,
    'firstHalfRadialBar'        => 50,
    'secondHalfRadialBar'       => 50
);

my %styleSectionStatus = (
    'javadoc'                   => 1,
    'indentation'               => 1,
    'whitespace'                => 1,
    'lineLength'                => 1,
    'other'                     => 1,
    'pointsGainedPercent'       => 100
);

my %testingSectionStatus = (
    'errors'                    => 1,
    'failures'                  => 1,
    'methodsUncovered'          => 1,
    'statementsUncovered'       => 1,
    'conditionsUncovered'       => 1,
    'resultsPercent'            => 100,
    'codeCoveragePercent'       => 100
);

my %behaviorSectionStatus = (
    'errors'                    => 1,
    'stackOverflowErrors'       => 1,
    'testsTakeTooLong'          => 1,
    'failures'                  => 1,
    'outOfMemoryErrors'         => 1,
    'problemCoveragePercent'    => 100
);

# A limit for number of errors in a subcategory in the feedback.
# Example: codingFlaws is a subcategory.
my $maxErrorsPerSubcategory = 8;

# A limit for number of lines above assertion failure in Testing section.
my $linesAboveAssertionFailure = 5;

# To know which among the above four sections should be expanded-
# Based on which one first contains errors in the following order:
# Coding(1), Testing(2), Behavior(3), Style (4).
my $expandSectionId = -1;

# Traverse over the expanded section hashmaps using the order from below
# arrays.
my @codingSectionOrder = (
    'compilerErrors',
    'compilerWarnings',
    'signatureErrors',
    'codingFlaws',
    'junitTests');

my @styleSectionOrder = (
    'javadoc',
    'indentation',
    'whitespace',
    'lineLength',
    'other');

my @testingSectionOrder = (
    'errors',
    'failures',
    'methodsUncovered',
    'statementsUncovered',
    'conditionsUncovered');

my @behaviorSectionOrder = (
    'errors',
    'stackOverflowErrors',
    'testsTakeTooLong',
    'failures',
    'outOfMemoryErrors');

my %codingSectionTitles = (
    'compilerErrors'            => 'Compiler Errors',
    'compilerWarnings'          => 'Compiler Warnings',
    'signatureErrors'           => 'Signature Errors',
    'codingFlaws'               => 'Potential Coding Bugs',
    'junitTests'                => 'Unit Test Coding Problems'
);

my %styleSectionTitles = (
    'javadoc'                   => 'JavaDoc',
    'indentation'               => 'Indentation Problems',
    'whitespace'                => 'Whitespace Problems',
    'lineLength'                => 'Line Length Problems',
    'other'                     => 'Other Style Problems'
);

my %testingSectionTitles = (
    'errors'                    => 'Unit Test Errors',
    'failures'                  => 'Unit Test Failures',
    'methodsUncovered'          => 'Unexecuted Methods',
    'statementsUncovered'       => 'Unexecuted Statements',
    'conditionsUncovered'       => 'Unexecuted Conditions'
);

my %behaviorSectionTitles = (
    'errors'                    => 'Unexpected Exceptions',
    'stackOverflowErrors'       => 'Infinite Recursion Problems',
    'testsTakeTooLong'          => 'Infinite Looping Problems',
    'failures'                  => 'Behavior Issues',
    'outOfMemoryErrors'         => 'Out of Memory Errors'
);


# expandedSection Content-each element in the hashmap is an array of structs
# (expandedMessage)
my %codingSectionExpanded = (
    'compilerErrors'            => undef,
    'compilerWarnings'          => undef,
    'signatureErrors'           => undef,
    'codingFlaws'               => undef,
    'junitTests'                => undef
);

my %styleSectionExpanded = (
    'javadoc'                   => undef,
    'indentation'               => undef,
    'whitespace'                => undef,
    'lineLength'                => undef,
    'other'                     => undef
);

my %testingSectionExpanded = (
    'errors'                    => undef,
    'failures'                  => undef,
    'methodsUncovered'          => undef,
    'statementsUncovered'       => undef,
    'conditionsUncovered'       => undef
);

my %behaviorSectionExpanded = (
    'errors'                    => undef,
    'stackOverflowErrors'       => undef,
    'testsTakeTooLong'          => undef,
    'failures'                  => undef,
    'outOfMemoryErrors'         => undef
);

# Temporary hashes to hold structs per file (for compiler errors and warnings)
# or rule (for all others) for expanded section.
# This is a multidimensional hash of the following form:
# 'compilerErrors'---'count'--'file or rule name'--count value
# 'compilerErrors'---'data'--'file or rule name'--array of structs
my %perFileRuleStruct = (
    'compilerErrors'            => undef,
    'compilerWarnings'          => undef,
    'signatureErrors'           => undef,
    'codingFlaws'               => undef,
    'junitTests'                => undef,
    'javadoc'                   => undef,
    'indentation'               => undef,
    'whitespace'                => undef,
    'lineLength'                => undef,
    'other'                     => undef,
    'errors'                    => undef,
    'failures'                  => undef,
    'methodsUncovered'          => undef,
    'statementsUncovered'       => undef,
    'conditionsUncovered'       => undef,
    'behaviorErrors'            => undef,
    'stackOverflowErrors'       => undef,
    'testsTakeTooLong'          => undef,
    'behaviorFailures'          => undef,
    'outOfMemoryErrors'         => undef
);


#-------------------------------------------------------
# In addition, some local definitions within this script
#-------------------------------------------------------
Web_CAT::Utilities::initFromConfig($cfg);
if (defined($ENV{JAVA_HOME}))
{
    # Make sure selected Java is at the head of the path ...
    $ENV{PATH} =
        "$ENV{JAVA_HOME}" . $Web_CAT::Utilities::FILE_SEPARATOR . "bin"
        . $Web_CAT::Utilities::PATH_SEPARATOR . $ENV{PATH};
}

die "ANT_HOME environment variable is not set! (Should come from ANTForPlugins)"
    if !defined($ENV{ANT_HOME});
$ENV{PATH} =
    "$ENV{ANT_HOME}" . $Web_CAT::Utilities::FILE_SEPARATOR . "bin"
    . $Web_CAT::Utilities::PATH_SEPARATOR . $ENV{PATH};

my $ANT                 = "ant";
my $callAnt             = 1;
my $antLogRelative      = "ant.log";
my $antLog              = "$resultDir/$antLogRelative";
my $scriptLogRelative   = "script.log";
my $scriptLog           = "$resultDir/$scriptLogRelative";
my $markupPropFile      = "$pluginHome/markup.properties";
my $pdfPrintoutRelative = "$pid.pdf";
my $pdfPrintout         = "$resultDir/$pdfPrintoutRelative";
my $diagramsRelative    = "diagrams";
my $diagrams            = "$publicDir/$diagramsRelative";
my $can_proceed         = 1;
my $buildFailed         = 0;
my $antLogOpen          = 0;
my $postProcessingTime  = 20;


#-------------------------------------------------------
# In the future, these could be set via parameters set in Web-CAT's
# interface
#-------------------------------------------------------
my $debug             = $cfg->getProperty('debug',      0);
my $hintsLimit        = $cfg->getProperty('hintsLimit', 3);
my $maxRuleDeduction  = $cfg->getProperty('maxRuleDeduction', $maxToolScore);
my $expSectionId      = $cfg->getProperty('expSectionId', 0);
my $defaultMaxBeforeCollapsing = 100000;
my $toolDeductionScaleFactor =
    $cfg->getProperty('toolDeductionScaleFactor', 1);
my $coverageMetric    = $cfg->getProperty('coverageMetric', 0);
my $minCoverageLevel =
    $cfg->getProperty('minCoverageLevel', 0.0);
my $coverageGoal =
    $cfg->getProperty('coverageGoal', 100.0);
if ($coverageGoal <= 0) { $coverageGoal = 100; }
if ($coverageGoal >= 1) { $coverageGoal /= 100.0; }

my $useXvfb =
    $cfg->getProperty('useXvfb', 0);
$useXvfb = ($useXvfb =~ m/^(true|on|yes|y|1)$/i);
if ($useXvfb)
{
    $ANT = 'xvfb-run -a -s "-c -screen 0 1280x1024x24" ' . $ANT;
}
my $allStudentTestsMustPass =
    $cfg->getProperty('allStudentTestsMustPass', 0);
$allStudentTestsMustPass =
    ($allStudentTestsMustPass =~ m/^(true|on|yes|y|1)$/i);
my $studentsMustSubmitTests =
    $cfg->getProperty('studentsMustSubmitTests', 0);
$studentsMustSubmitTests =
    ($studentsMustSubmitTests =~ m/^(true|on|yes|y|1)$/i);
if (!$studentsMustSubmitTests) { $allStudentTestsMustPass = 0; }
my $includeTestSuitesInCoverage =
    $cfg->getProperty('includeTestSuitesInCoverage', 0);
$includeTestSuitesInCoverage =
    ($includeTestSuitesInCoverage =~ m/^(true|on|yes|y|1)$/i);
my $requireSimpleExceptionCoverage =
    $cfg->getProperty('requireSimpleExceptionCoverage', 0);
$requireSimpleExceptionCoverage =
    ($requireSimpleExceptionCoverage =~ m/^(true|on|yes|y|1)$/i);
my $requireSimpleGetterSetterCoverage =
    $cfg->getProperty('requireSimpleGetterSetterCoverage', 0);
$requireSimpleGetterSetterCoverage =
    ($requireSimpleGetterSetterCoverage =~ m/^(true|on|yes|y|1)$/i);
my $junitErrorsHideHints =
    $cfg->getProperty('junitErrorsHideHints', 0);
$junitErrorsHideHints =
    ($junitErrorsHideHints =~ m/^(true|on|yes|y|1)$/i)
    && $studentsMustSubmitTests;
{
    # Suppress hints if another plug-in in the pipeline will be handling them
    my $hintProcessor = $cfg->getProperty('pipeline.hintProcessor');
    if (defined $hintProcessor &&
        $hintProcessor ne $cfg->getProperty('pluginName', 'JavaTddPlugin'))
    {
        $hintsLimit = 0;
    }
}


#=============================================================================
# Adjust hints limit, if needed
#=============================================================================
my $extraHintMsg = "";
if ($hintsLimit)
{
    my $hideHintsWithin = $cfg->getProperty('hideHintsWithin', 0);
    if ($hideHintsWithin > 0)
    {
        my $daysBeforeDeadline =
            ($cfg->getProperty('dueDateTimestamp', 0)
            - $cfg->getProperty('submissionTimestamp', 0))
            / (1000 * 60 * 60 * 24);
        if ($daysBeforeDeadline > 0 && $daysBeforeDeadline < $hideHintsWithin)
        {
            # Then we're within X days of deadline.  Check to see if we're
            # within the re-enable window
            my $showHintsWithin = $cfg->getProperty('showHintsWithin', 0);
            if ($daysBeforeDeadline > $showHintsWithin)
            {
                $hintsLimit = 0;
                my $days = "day";
                if ($hideHintsWithin != 1)
                {
                    $days .= "s";
                }
                $extraHintMsg = "Hints are not available within "
                    . "$hideHintsWithin $days of the deadline.";
                if ($showHintsWithin > 0)
                {
                    $days = "day";
                    if ($showHintsWithin != 1)
                    {
                        $days .= "s";
                    }
                    $extraHintMsg .= "  Hints will be available again "
                        . "$showHintsWithin $days before the deadline.";
                }
            }
        }
    }
}


#=============================================================================
# Transform simple java file patterns to
#=============================================================================
sub setClassPatternIfNeeded
{
    my $inProperty = shift || carp "incoming property name required";
    my $outProperty = shift || carp "outgoing property name required";
    my $useJavaExtension = shift;

    if (!defined $useJavaExtension)
    {
        $useJavaExtension = 0;
    }

    my $inExtension  = $useJavaExtension ? ".class" : ".java";
    my $outExtension = $useJavaExtension ? ".java"  : ".class";

    my $value = $cfg->getProperty($inProperty);
    if (defined $value && $value ne '')
    {
        my $pattern = undef;
        foreach my $include (split(/[,\s]+/, $value))
        {
            # print "processing class pattern: '$include'\n";
            if (defined($include) && $include ne '')
            {
                if ($include !~ m/^none$/io)
                {
                    $include =~ s,\\,/,go;
                    if ($include =~ /\./)
                    {
                        $include =~ s/\Q$inExtension\E$/$outExtension/i;
                    }
                    else
                    {
                        $include .= $outExtension;
                    }
                    if ($include !~ m,^\*\*/,o)
                    {
                        $include = "**/$include";
                    }
                }

                if (defined $pattern)
                {
                    $pattern .= " $include";
                }
                else
                {
                    $pattern = $include;
                }
            }
            # print "new pattern: '$pattern'\n";
        }
        if (defined $pattern)
        {
            $cfg->setProperty($outProperty, $pattern);
        }
    }
}


#=============================================================================
# Turn include/exclude class names into file patterns
#=============================================================================

{
    my $cloverIncludes = $cfg->getProperty('clover.includes', '**');
    my @files = split(/[,\s]+/, $cloverIncludes);
    for (my $i = 0; $i <= $#files; $i++)
    {
        if ($files[$i] !~ /\*/)
        {
            $files[$i] = '**/' . $files[$i] . '.*';
        }
    }
    $cloverIncludes = join(' ', @files);
    $cfg->setProperty('clover.includes', $cloverIncludes);
}

{
    my $cloverExcludes = $cfg->getProperty('clover.excludes', '**');
    my @files = split(/[,\s]+/, $cloverExcludes);
    for (my $i = 0; $i <= $#files; $i++)
    {
        if ($files[$i] !~ /\*/)
        {
            $files[$i] = '**/' . $files[$i] . '.*';
        }
    }
    $cloverExcludes = join(' ', @files);
    $cfg->setProperty('clover.excludes', $cloverExcludes);
}


#=============================================================================
# Generate derived properties for ANT
#=============================================================================
# testCases
my $scriptData = $cfg->getProperty('scriptData', '.');
$scriptData =~ s,/$,,;

# testCases (reference test location and/or file name).
# This first var needs to be visible for later pattern matching to remove
# internal path names from student messages.
my $testCasePathPattern;
{
    my $testCasePath = "${pluginHome}/tests";
    my $testCaseFileOrDir = $cfg->getProperty('testCases');
    if (defined $testCaseFileOrDir && $testCaseFileOrDir ne "")
    {
        my $target = confirmExists($scriptData, $testCaseFileOrDir);
        if (-d $target)
        {
            $cfg->setProperty('testCasePath', $target);
        }
        else
        {
            $cfg->setProperty('testCasePath', dirname($target));
            $cfg->setProperty('testCasePattern', basename($target));
            $cfg->setProperty('justOneTestClass', 'true');
        }
        $testCasePath = $target;
    }
    $testCasePathPattern = filePattern($testCasePath);
}

# Set up other test case filtering patterns
setClassPatternIfNeeded('refTestInclude', 'refTestClassPattern');
setClassPatternIfNeeded('refTestExclude', 'refTestClassExclusionPattern');
setClassPatternIfNeeded('studentTestInclude', 'studentTestClassPattern');
setClassPatternIfNeeded('studentTestExclude',
    'studentTestClassExclusionPattern');
setClassPatternIfNeeded('staticAnalysisInclude', 'staticAnalysisSrcPattern', 1);
setClassPatternIfNeeded('staticAnalysisExclude',
    'staticAnalysisSrcExclusionPattern', 1);
setClassPatternIfNeeded('staticAnalysisExclude',
    'instrumentExclusionPattern');

# useDefaultJar
{
    my $useDefaultJar = $cfg->getProperty('useDefaultJar');
    if (defined $useDefaultJar && $useDefaultJar =~ /false|\b0\b/i)
    {
        $cfg->setProperty('defaultJars', "$pluginHome/empty");
    }
}

# assignmentJar
{
    my $jarFileOrDir = $cfg->getProperty('assignmentJar');
    if (defined $jarFileOrDir && $jarFileOrDir ne "")
    {
        my $path = confirmExists($scriptData, $jarFileOrDir);
        $cfg->setProperty('assignmentClassFiles', $path);
        if (-d $path)
        {
            $cfg->setProperty('assignmentClassDir', $path);
        }
    }
}

# classpathJar
{
    my $jarFileOrDir = $cfg->getProperty('classpathJar');
    if (defined $jarFileOrDir && $jarFileOrDir ne "")
    {
        my $path = confirmExists($scriptData, $jarFileOrDir);
        $cfg->setProperty('instructorClassFiles', $path);
        if (-d $path)
        {
            $cfg->setProperty('instructorClassDir', $path);
        }
    }
}

# useAssertions
{
    my $useAssertions = $cfg->getProperty('useAssertions');
    if (defined $useAssertions && $useAssertions !~ m/^(true|yes|1|on)$/i)
    {
        $cfg->setProperty('enableAssertions', '-da');
    }
}

# checkstyleConfig
{
    my $checkstyle = $cfg->getProperty('checkstyleConfig');
    if (defined $checkstyle && $checkstyle ne "")
    {
        $cfg->setProperty(
            'checkstyleConfigFile', confirmExists($scriptData, $checkstyle));
    }
}

# pmdConfig
{
    my $pmd = $cfg->getProperty('pmdConfig');
    if (defined $pmd && $pmd ne "")
    {
        $cfg->setProperty(
            'pmdConfigFile', confirmExists($scriptData, $pmd));
    }
}

# policyFile
{
    my $policy = $cfg->getProperty('policyFile');
    if (defined $policy && $policy ne "")
    {
        $cfg->setProperty(
            'javaPolicyFile', confirmExists($scriptData, $policy));
    }
}

# security.manager
{
    if ($debug >= 5)
    {
        $cfg->setProperty(
            'security.manager',
            'java.security.manager=net.sf.webcat.plugins.javatddplugin.'
            . 'ProfilingSecurityManager');
    }
}

# markupProperties
{
    my $markup = $cfg->getProperty('markupProperties');
    if (defined $markup && $markup ne "")
    {
        $markupPropFile = confirmExists($scriptData, $markup);
    }
}


# wantPDF
{
    my $p = $cfg->getProperty('wantPDF');
    if (defined $p && $p !~ /false/i)
    {
        $cfg->setProperty('generatePDF', '1');
        $cfg->setProperty('PDF.dest', $pdfPrintout);
    }
}


# timeout
my $timeoutForOneRun = $cfg->getProperty('timeoutForOneRun', 30);
$cfg->setProperty('exec.timeout', $timeoutForOneRun * 1000);


$cfg->save();


#=============================================================================
# Script Startup
#=============================================================================
# Change to specified working directory and set up log directory
chdir($workingDir);

# try to deduce whether or not there is an extra level of subdirs
# around this assignment
{
    # Get a listing of all file/dir names, including those starting with
    # dot, then strip out . and ..
    my @dirContents = grep(!/^(\.{1,2}|META-INF|__MACOSX)$/,
        (bsd_glob("*"), bsd_glob(".*")));

    # if this list contains only one entry that is a dir name != src, then
    # assume that the submission has been "wrapped" with an outter
    # dir that isn't actually part of the project structure.
    if ($#dirContents == 0 && -d $dirContents[0] && $dirContents[0] ne "src")
    {
        # Strip non-alphanumeric symbols from dir name
        my $dir = $dirContents[0];
        if ($dir =~ s/[^a-zA-Z0-9_]//g)
        {
            if ($dir eq "")
            {
                $dir = "dir";
            }
            rename($dirContents[0], $dir);
        }
        $workingDir .= "/$dir";
        chdir($workingDir);
    }
}

# Screen out any temporary files left around by BlueJ
{
    my @javaSrcs = < __SHELL*.java >;
    foreach my $tempFile (@javaSrcs)
    {
        unlink($tempFile);
    }
}


if ($debug)
{
    print "working dir set to $workingDir\n";
    print "JAVA_HOME = ", $ENV{JAVA_HOME}, "\n";
    print "ANT_HOME  = ", $ENV{ANT_HOME}, "\n";
    print "PATH      = ", $ENV{PATH}, "\n\n";
}

# localFiles
{
    my $localFiles = $cfg->getProperty('localFiles');
    if (defined $localFiles && $localFiles ne "")
    {
        my $lf = confirmExists($scriptData, $localFiles);
        print "localFiles = $lf\n" if $debug;
        if (-d $lf)
        {
            print "localFiles is a directory\n" if $debug;
            copyHere($lf, $lf, \@beautifierIgnoreFiles);
        }
        else
        {
            print "localFiles is a single file\n" if $debug;
            $lf =~ tr/\\/\//;
            my $base = $lf;
            $base =~ s,/[^/]*$,,;
            copyHere($lf, $base, \@beautifierIgnoreFiles);
        }
    }
}


#=============================================================================
# Run the ANT build file to get all the results
#=============================================================================
my $time1        = time;
#my $studentResults    = new Web_CAT::JUnitResultsReader();
#my $instructorResults = new Web_CAT::JUnitResultsReader();
#my $testsRun     = 0; #0
#my $testsFailed  = 0;
#my $testsErrored = 0;
#my $testsPassed  = 0;

if ($callAnt)
{
    if ($debug > 2)
    {
        $ANT .= " -d -v";
        if ($debug > 5)
        {
            $ANT .= " -logger org.apache.tools.ant.listener.ProfileLogger";
        }
    }

    my $cmdline = $Web_CAT::Utilities::SHELL
        . "$ANT -f \"$pluginHome/build.xml\" -l \"$antLog\" "
        . "-propertyfile \"$propfile\" \"-Dbasedir=$workingDir\" "
        . "2>&1 > " . File::Spec->devnull;

    print $cmdline, "\n" if ($debug);
    my ($exitcode, $timeout_status) = Proc::Background::timeout_system(
        $timeout - $postProcessingTime, $cmdline);
    if ($timeout_status)
    {
        # Mark Behavior Section-tests taking too long
        $behaviorSectionStatus{'testsTakeTooLong'} = 0;

        $can_proceed = 0;
        $status{'antTimeout'} = 1;
        $buildFailed = 1;
        # FIXME: Move to end of $status{'feedback'} ...
        $status{'feedback'}->startFeedbackSection(
            "Errors During Testing", ++$expSectionId);
        $status{'feedback'}->print(<<EOF);
<p><b class="warn">Testing your solution exceeded the allowable time
limit for this assignment.</b></p>
<p>Most frequently, this is the result of <b>infinite recursion</b>--when
a recursive method fails to stop calling itself--or <b>infinite
looping</b>--when a while loop or for loop fails to stop repeating.
</p>
<p>
As a result, no time remained for further analysis of your code.</p>
EOF
        $status{'feedback'}->endFeedbackSection;
    }
}

my $time2 = time;
if ($debug)
{
    print "\n", ($time2 - $time1), " seconds\n";
}
my $time3 = time;


#=============================================================================
# check for compiler error (or warnings)
#    report only the first file causing errors
#=============================================================================

#-----------------------------------------------
# Generate a script warning
sub adminLog
{
    open(SCRIPTLOG, ">>$scriptLog") ||
        die "Cannot open file for output '$scriptLog': $!";
    print SCRIPTLOG join("\n", @_), "\n";
    close(SCRIPTLOG);
}

my $cannotFindSymbolStruct;

# generate compilerError and compilerWarning Structs.
# We pick only the first occurring error or warning in a file.
sub generateCompilerErrorWarningStruct
{
    my $messageString = shift;
    my $key = shift;
    my $splitString;
    my $errorStruct;

    if (index(lc($key), 'error') != -1)
    {
        $splitString = 'error:';
    }
    else
    {
        $splitString = 'warning:';
    }

    my @messageContents = split($splitString, $messageString);

    my @fileDetails = split(':', $messageContents[0]);
    #trim the message
    $messageContents[1] =~ s/^\s+|\s+$//g;

    my $fileName = $fileDetails[0];
    $fileName =~ s,\\,/,go;
    my $lineNum = $fileDetails[1];
    my $codeLines = extractAboveBelowLinesOfCode($fileName, $lineNum);
    $fileName =~ s,^\Q$workingDir/\E,,i;

    # For compiler warning we dont have enhanced messages
    # For "cannot find symbol" errors, "addCannotFindSymbolStruct" computes
    # the enhaced message
    if ($splitString eq 'warning:'
        || $messageContents[1] eq 'cannot find symbol')
    {
        $errorStruct = expandedMessage->new(
            entityName => $fileName,
            lineNum => $lineNum,
            errorMessage => $messageContents[1],
            linesOfCode => $codeLines,
            enhancedMessage => '',
            );
    }
    else
    {
        $errorStruct = expandedMessage->new(
            entityName => $fileName,
            lineNum => $lineNum,
            errorMessage => $messageContents[1],
            linesOfCode => $codeLines,
            enhancedMessage =>
                compilerErrorEnhancedMessage($messageContents[1]),
            );
    }

    # If the struct contains only "cannot find symbol" then we look for the
    # next line in the ant.log to obtain symbol name and add the struct later
    if ($errorStruct->errorMessage eq 'cannot find symbol')
    {
        $cannotFindSymbolStruct = $errorStruct;
        return;
    }

    if (defined $perFileRuleStruct{$key}{'data'}{$fileName})
    {
        $perFileRuleStruct{$key}{'count'}{$fileName}++;
    }
    else
    {
        $perFileRuleStruct{$key}{'data'}{$fileName} = $errorStruct;
        $perFileRuleStruct{$key}{'count'}{$fileName} = 1;
    }
}

sub addCannotFindSymbolStruct
{
    if (not defined $cannotFindSymbolStruct)
    {
        return;
    }

    my $symbolName = shift;
    #Replace multiple spaces by single space
    $symbolName =~ tr/ //s;
    $symbolName =~ s/^\bsymbol\s+symbol\b/symbol/io;

    my $errorMessage = $cannotFindSymbolStruct->errorMessage;
    $errorMessage .= $symbolName;

    my $errorStruct = expandedMessage->new(
        entityName => $cannotFindSymbolStruct->entityName,
        lineNum => $cannotFindSymbolStruct->lineNum,
        errorMessage => $errorMessage,
        linesOfCode => $cannotFindSymbolStruct->linesOfCode,
        enhancedMessage => compilerErrorEnhancedMessage($errorMessage),
        );

    $cannotFindSymbolStruct = undef;

    if (defined $perFileRuleStruct{'compilerErrors'}{'data'}{$errorStruct->entityName})
    {
        $perFileRuleStruct{' Errors'}{'count'}{$errorStruct->entityName}++;

    }
    else
    {
        $perFileRuleStruct{'compilerErrors'}{'data'}{$errorStruct->entityName} = $errorStruct;
        $perFileRuleStruct{'compilerErrors'}{'count'}{$errorStruct->entityName} = 1;
    }
}

#-----------------------------------------------
my %suites = ();
if ($can_proceed)
{

    open(ANTLOG, "$antLog") ||
        die "Cannot open file for input '$antLog': $!";
    $antLogOpen++;

    $_ = <ANTLOG>;

    scanTo(qr/^(compile:|BUILD FAILED)/);
    $buildFailed++ if defined($_)  &&  m/^BUILD FAILED/;
    $_ = <ANTLOG>;

    scanThrough(qr/^\s*\[(?!javac\])/);
    scanThrough(qr/^\s*($|\[javac\](?!\s+Compiling))/);
    if (!defined($_)  ||  $_ !~ m/^\s*\[javac\]\s+Compiling/)
    {
        # The student failed to include any source files!
        $status{'studentHasSrcs'} = 0;
        $status{'feedback'}->startFeedbackSection(
            "Compilation Produced Errors", ++$expSectionId);
        $status{'feedback'}->print(<<EOF);
<p>Your submission did not include any Java source files, so none
were compiled.
</p>
EOF
        $status{'feedback'}->endFeedbackSection;
        $can_proceed = 0;
    }
    else
    {
        $status{'studentHasSrcs'} = 1;
        $_ = <ANTLOG>;

        my $projdir  = $workingDir;
        $projdir .= "/" if ($projdir !~ m,/$,);
        $projdir = filePattern($projdir);
        my $compileMsgs    = "";
        my $compileErrs    = 0;
        my $compileWarnings = 0;
        my $firstFile      = "";
        my $collectingMsgs = 1;

        print "projdir = '$projdir'\n" if $debug;

        while (defined($_)  &&  s/^\s*\[javac\] //o)
        {

            my $wrap = 0;
            if (s/^$projdir//io)
            {
                # print "trimmed: $_";
                if ($firstFile eq "" && m/^([^:]*):/o)
                {

                    $firstFile = $1;

                    $firstFile =~ s,\\,\\\\,g;
                    # print "firstFile='$firstFile'\n";
                }
                elsif ($_ !~ m/^$firstFile/)
                {
                    # print "stopping collection: $_";
                    $collectingMsgs = 0;
                }
                elsif ($_ =~ m/^$firstFile/ && !$collectingMsgs)
                {
                    # print "restarting collection: $_";
                    $collectingMsgs = 1;
                }
                chomp;
                $wrap = 1;
            }
            if (m/^[1-9][0-9]*\s.*error/o)
            {
                # print "err: $_";
                $compileErrs++;
                $collectingMsgs = 1;
                $can_proceed = 0;
                $buildFailed = 1;

                # set CompilerErrors flag to reflect that it didnt pass.
                $codingSectionStatus{'compilerErrors'} = 0;

            }
            if (m/^[1-9][0-9]*\s.*warning/o)
            {
                $compileWarnings++;

                # set CompilerWarnings flag to reflect that it didnt pass.
                $codingSectionStatus{'compilerWarnings'} = 0;
            }

            if (m/error:/o or m/warning:/o)
            {
                if (m/error:/o)
                {
                    generateCompilerErrorWarningStruct($_, 'compilerErrors' );
                }

                if (m/warning:/o)
                {
                    generateCompilerErrorWarningStruct($_, 'compilerWarnings');
                }
            }

            if (m/symbol:/o)
            {
                # This essentially contains the symbol name.
                # Example: 'symbol symbol: food'
                addCannotFindSymbolStruct($_);
            }


            if ($collectingMsgs)
            {
                $_ = htmlEscape($_);

                if ($wrap)
                {
                    $_ = "<b class=\"warn\">" . $_ . "</b>\n";
                }
                $compileMsgs .= $_;

            }
            $_ = <ANTLOG>;

        }

        if ($compileErrs > 0)
        {
            $status{'compileErrs'}++;
            @{$codingSectionExpanded{'compilerErrors'}} =
                addStructsToExpandedSectionsFromScalarHashValues(
                'compilerErrors');
        }

        if ($compileWarnings > 0)
        {
            @{$codingSectionExpanded{'compilerWarnings'}} =
                addStructsToExpandedSectionsFromScalarHashValues(
                'compilerWarnings');
        }

        if ($compileMsgs ne "" && !$useEnhancedFeedback)
        {
            $status{'feedback'}->startFeedbackSection(
                ($compileErrs)
                ? "Compilation Produced Errors"
                : "Compilation Produced Warnings",
                ++$expSectionId);
            $status{'feedback'}->print("<pre>\n");
            $status{'feedback'}->print($compileMsgs);
            $status{'feedback'}->print("</pre>\n");
            $status{'feedback'}->endFeedbackSection;
        }

    }


#=============================================================================
# collect JUnit testing stats from instructor-provided tests
#=============================================================================
    if ($can_proceed)
    {
        scanTo(qr/^(compile\.instructor\.tests:|BUILD FAILED)/);
        $buildFailed++ if defined($_)  &&  m/^BUILD FAILED/;
        $_ = <ANTLOG>;
        scanTo(qr/^(\s*\[javac\]\s+Compiling|BUILD FAILED)/);
        if (!defined($_)  ||  $_ !~ m/^\s*\[javac\]\s+Compiling/)
        {
            adminLog("Failed to compile instructor test cases!\nCannot "
                      . "find \"[javac] Compiling <n> source files\" ... "
                      . "in line:\n$_");
        }
        else
        {
            $_ = <ANTLOG>;
            scanTo(qr/^(\s*\[javac\] |(instructor\.)?test(.?):|BUILD)/);
        }
        my $instrHints     = "";
        my %instrHintCollection = ();
        my $collectingMsgs = 0;
        while (defined($_)  &&  s/^\s*\[javac\] //o)
        {
            # print "msg: $_\n";
            # print "tcp: $testCasePathPattern\n";
            if (/^$testCasePathPattern/o)
            {
                # print "    match\n";
                $collectingMsgs++;
                $_ =~ s/^\S*\s*//o;
            }
            elsif (/^location/o)
            {
                $_ = "";
            }
            if (m/^[1-9][0-9]*\s.*error/o)
            {
                # print "err: $_";
                $status{'compileErrs'}++;
            }
            if (m/^Compile failed;/o)
            {
                $collectingMsgs = 0;
            }
            if ($collectingMsgs)
            {
                $status{'compileMsgs'} .= htmlEscape($_);
            }
            $_ = <ANTLOG>;
            scanTo(qr/^(\s*\[javac\] |(instructor\.)?test(.?):|BUILD)/);
        }

        scanTo(qr/^((instructor\.)?test(.?):|BUILD FAILED)/);
        $buildFailed++ if defined($_)  &&  m/^BUILD FAILED/;
        if (m/^instructor-/)
        {
            # FIXME--anything to do here?
        }
    }

    $time3 = time;
    if ($debug)
    {
        print "\n", ($time3 - $time2), " seconds\n";
    }


#=============================================================================
# collect JUnit testing stats
#=============================================================================
    if ($can_proceed)
    {
        scanTo(qr/^(test:|BUILD FAILED)/);
        $buildFailed++ if defined($_)  &&  m/^BUILD FAILED/;
        # FIXME--anything to do here?
    }

    if ($can_proceed)
    {
        scanTo(qr/^BUILD FAILED/);
        if (defined($_)  &&  m/^BUILD FAILED/)
        {
            warn "ant BUILD FAILED unexpectedly.";
            $can_proceed = 0;
            $buildFailed++;
        }
    }

    $status{'studentTestResults'} =
        new Web_CAT::JUnitResultsReader("$resultDir/student.inc");
    $status{'instrTestResults'} =
        new Web_CAT::JUnitResultsReader("$resultDir/instr.inc");

    foreach my $class ($status{'studentTestResults'}->suites)
    {
        my $pkg = "";
        my $simpleClassName = $class;
        if ($class =~ m/^(.+)\.([^\.]+)/o)
        {
            $pkg = $1;
            $simpleClassName = $2;
        }
        $simpleClassName =~ s/\$.*$//o;
        if (!defined $suites{$pkg})
        {
            $suites{$pkg} = {};
        }
        $suites{$pkg}->{$simpleClassName} = $class;
        print "suite: $pkg -> $simpleClassName -> $class\n" if ($debug > 2);
    }
}

if ($antLogOpen)
{
    close(ANTLOG);
}

my $time4 = time;
if ($debug)
{
    print "\n", ($time4 - $time3), " seconds\n";
}


#=============================================================================
# Load checkstyle and PMD reports into internal data structures
#=============================================================================

# The configuration file for scoring tool messages
my $ruleProps = Config::Properties::Simple->new(file => $markupPropFile);

# The message groups defined by the instructor
my @groups = split(qr/,\s*/, $ruleProps->getProperty("groups", ""));

# The same list, but as a hash, initialized by this for loop
my %groups = ();
foreach my $group (@groups)
{
    $groups{$group} = 1;
}

# We'll co-opt the XML::Smart structure to record the following
# info about messages:
# messageStats->group->rule->filename->{num, pts, collapse}
# messageStats->group->rule->{num, pts, collapse}
# messageStats->group->{num, pts, collapse}
# messageStats->group->file->filename->{num, pts, collapse}
# messageStats->{num, pts, collapse}
# messageStats->file->filename->{num, pts, collapse}
my $messageStats = XML::Smart->new();

# %codeMessages is a hash like this:
# {
#   filename1 => {
#                  <line num> => {
#                                   category => coverage,
#                                   coverage => "...",
#                                   message  => "...",
#                                   violations => [ ... ]
#                                },
#                  <line num> => { ...
#                                },
#                },
#   filename2 => { ...
#                },
# }
#
# If the line number entry has a category => coverage, it is a
# coverage highlight request (but it might not have one).
#
# If the line number entry for a file has a violations key, it
# is a ref to an array of violation objects, keyed by file name (relative
# to $workingDir, using forward slashes).  Each violation object is
# a reference to an XML::Smart node:
# ... was a hash like this, but now ...
# {
#     group         => ...
#     category      => ...
#     message       => ...
#     deduction     => ...
#     limitExceeded => ...
#     lineNo        => ...
#     URL           => ...
#     source        => ...
# }
# Both the "to" and "fileName" fields are omitted, since "to" is
# always "all" and the fileName is the key mapping to (a list of)
# these.

my %codeMessages = ();

#-----------------------------------------------
# ruleSetting(rule, prop [, default])
#
# Retrieves a rule parameter from the config file, tracing through the
# default hierarchy if necessary.  Parameters:
#
#     rule:    the string name of the rule to look for
#     prop:    the name of the setting to look up
#     default: value to use if no setting is recorded in the configuration
#              file (or undef, if omitted)
#
#  The search order is as follows:
#
#     <rule>.<prop>              = value
#     <group>.ruleDefault.<prop> = value
#     ruleDefault.<prop>         = value
#     <default> (if provided)
#
# Here, <group> is the group name for the given rule, as determined
# by <rule>.group (or ruleDefault.group).
#
sub ruleSetting
{
    croak "usage: ruleSetting(rule, prop [, default])"
        if ($#_ < 1 || $#_ > 2);
    my $rule    = shift;
    my $prop    = shift;
    my $default = shift;

    my $val = $ruleProps->getProperty("$rule.$prop");
    if (!defined($val))
    {
        my $group = $ruleProps->getProperty("$rule.group");
        if (!defined($group))
        {
            $group = $ruleProps->getProperty("ruleDefault.group");
        }
        if (defined($group))
        {
            if (!defined($groups{$group}))
            {
                warn "group name '$group' not in groups property.\n";
            }
            $val = $ruleProps->getProperty("$group.ruleDefault.$prop");
        }
        if (!defined($val))
        {
            $val = $ruleProps->getProperty("ruleDefault.$prop");
        }
        if (!defined($val))
        {
            $val = $default;
        }
    }
    if (defined($val) && $val eq '${maxDeduction}')
    {
        $val = $maxRuleDeduction;
    }
    return $val;
}


#-----------------------------------------------
# groupSetting(group, prop [, default])
#
# Retrieves a group parameter from the config file, tracing through the
# default hierarchy if necessary.  Parameters:
#
#     group:   the string name of the group to look for
#     prop:    the name of the setting to look up
#     default: value to use if no setting is recorded in the configuration
#              file (or undef, if omitted)
#
# The search order is as follows:
#
#     <group>.group.<prop> = value
#     groupDefault.<prop>  = value
#     <default> (if provided)
#
sub groupSetting
{
    croak "usage: groupSetting(group, prop [, default])"
        if ($#_ < 1 || $#_ > 2);
    my $group   = shift;
    my $prop    = shift;
    my $default = shift;

    if (!defined($groups{$group}))
    {
        carp "group name '$group' not in groups property.\n";
    }
    my $val = $ruleProps->getProperty("$group.group.$prop");
    if (!defined($val))
    {
        if (!defined($val))
        {
            $val = $ruleProps->getProperty("groupDefault.$prop");
        }
        if (!defined($val))
        {
            $val = $default;
        }
    }
    if (defined($val) && $val eq '${maxDeduction}')
    {
        $val = $maxRuleDeduction;
    }
    return $val;
}


#-----------------------------------------------
# markupSetting(prop [, default])
#
# Retrieves a top-level parameter from the config file.
sub markupSetting
{
    croak "usage: markupSetting(prop [, default])"
        if ($#_ < 0 || $#_ > 1);
    my $prop    = shift;
    my $default = shift;

    my $val = $ruleProps->getProperty($prop, $default);
    if (defined($val) && $val eq '${maxDeduction}')
    {
        $val = $maxRuleDeduction;
    }
    return $val;
}


#-----------------------------------------------
# countRemarks(listRef)
#
# Counts the number of non-killed remarks in %messages for the
# given file name.
#
sub countRemarks
{
    my $list  = shift;
    my $count = 0;
    foreach my $v (@{ $list })
    {
        if ($v->{kill}->null)
        {
            $count++;
        }
    }
    return $count;
}


#-----------------------------------------------
# trackMessageInstanceInContext(
#       context             => ...,
#     [ maxBeforeCollapsing => ..., ]
#       maxDeductions       => ...,
#       deduction           => ref ...,
#       overLimit           => ref ...,
#       fileName            => ...,
#       violation           => ... )
#
sub trackMessageInstanceInContext
{
    my %args = @_;
    my $context = $args{context};

    if (!($context->{num}->null))
    {
        $context->{num} += 1;
    }
    else
    {
        $context->{num}      = 1;
        $context->{pts}      = 0;
        $context->{collapse} = 0;
    }
    if (defined($args{maxBeforeCollapsing}) &&
         $context->{num}->content > $args{maxBeforeCollapsing})
    {
        $context->{collapse} = 1;
    }
    # check for pts in file overflow
    if ($context->{pts}->content + ${ $args{deduction} } >
         $args{maxDeductions})
    {
        ${ $args{overLimit} }++;
        ${ $args{deduction} } =
            $args{maxDeductions} - $context->{pts}->content;
        if (${ $args{deduction} } < 0)
        {
            carp "deduction underflow, file ", $args{fileName}, ":\n",
                $args{violation}->data_pointer(noheader  => 1, nometagen => 1);
        }
    }
}

# Using a group mark the coding Section subsections appropriately.
sub markCodingSection
{
    my $group = shift;

    # Group for CodingFlaws is "coding", whereas "codingMinor" and
    # "codingWarning" will fall under "other" subcategory in Style category.
    if (lc($group) eq "coding")
    {
        $codingSectionStatus{'codingFlaws'} = 0;
    }
    elsif (index(lc($group), 'testing') != -1)
    {
        $codingSectionStatus{'junitTests'} = 0;
    }
}

# Use group and rule to mark the Style Section subsections appropriately.
sub markStyleSection
{
    my $rule = shift;
    my $group = shift;

    if (index(lc($rule), 'javadoc') != -1)
    {
        $styleSectionStatus{'javadoc'} = 0;
    }
    elsif (index(lc($rule), 'indentation') != -1)
    {
        $styleSectionStatus{'indentation'} = 0;
    }
    elsif (index(lc($rule), 'whitespace') != -1)
    {
        $styleSectionStatus{'whitespace'} = 0;
    }
    elsif (index(lc($rule), 'linelength') != -1)
    {
        $styleSectionStatus{'lineLength'} = 0;
    }
    elsif (lc($group) ne "coding" && index(lc($group),"testing") == -1)
    {
        # If its not marked in coding and style section(other four
        # subcategories).
        $styleSectionStatus{'other'} = 0;
    }
}

#-----------------------------------------------
# trackMessageInstance(rule, fileName, violation)
#
# Updates the $messageStats structure with the information for a given
# rule violation.
#
#     rule:      the name of the rule violated
#     fileName:  the source file name where the violation occurred
#                (relative to $workingDir)
#     violation: the XML::Smart structure referring to the violation
#                (used for error message printing only)
#
sub trackMessageInstance
{
    croak 'usage: recordPMDMessageStats(rule, fileName, violation)'
        if ($#_ != 2);
    my $rule      = shift;
    my $fileName  = shift;
    my $violation = shift;

    my $group     = ruleSetting($rule, 'group', 'defaultGroup');
    my $deduction = ruleSetting($rule, 'deduction', 0)
        * $toolDeductionScaleFactor;
    my $overLimit = 0;

    if (!$violation->{line}->content
      && $violation->{endline}->content)
    {
        $violation->{line} = $violation->{endline}->content;

        # In case of testing violations from pmd, we would use beginline for
        # rules like TestsHaveAssertions, as the endline would be the closing
        # curly brace of the method. This is the only case where endline is
        # different from beginline
        if (index(lc($group), 'testing') != -1
            && $violation->{beginline}->content
            && $violation->{beginline}->content
            != $violation->{endline}->content)
        {
            $violation->{beginline} = $violation->{beginline}->content;
        }
    }

    if ($debug > 1)
    {
        print "tracking $group, $rule, $fileName, ",
            $violation->{line}->content, "\n";
    }
    if ($group eq "testing")
    {
        $hasJUnitErrors++;
        if ($debug > 1)
        {
            print "found JUnit error!\n";
        }
    }

    markCodingSection($group);
    markStyleSection($rule, $group);

    # messageStats->group->rule->filename->{num, collapse} (pts later)
    trackMessageInstanceInContext(
            context           => $messageStats->{$group}->{$rule}->{$fileName},
            maxBeforeCollapsing => ruleSetting($rule, 'maxBeforeCollapsing',
                                               $defaultMaxBeforeCollapsing),
            maxDeductions       => ruleSetting($rule, 'maxDeductionsInFile',
                                               $maxRuleDeduction),
            deduction           => \$deduction,
            overLimit           => \$overLimit,
            fileName            => $fileName,
            violation           => $violation
       );

    # messageStats->group->rule->{num, collapse} (pts later)
    trackMessageInstanceInContext(
            context       => $messageStats->{$group}->{$rule},
            maxDeductions => ruleSetting($rule, 'maxDeductionsInAssignment',
                                         $maxToolScore),
            deduction     => \$deduction,
            overLimit     => \$overLimit,
            fileName      => $fileName,
            violation     => $violation
       );

    # messageStats->group->file->filename->{num, collapse} (pts later)
    trackMessageInstanceInContext(
            context       => $messageStats->{$group}->{file}->{$fileName},
            maxBeforeCollapsing => groupSetting($group, 'maxBeforeCollapsing',
                                                $defaultMaxBeforeCollapsing),
            maxDeductions => groupSetting($group, 'maxDeductionsInFile',
                                          $maxToolScore),
            deduction     => \$deduction,
            overLimit     => \$overLimit,
            fileName      => $fileName,
            violation     => $violation
       );

    # messageStats->group->{num, collapse} (pts later)
    trackMessageInstanceInContext(
            context       => $messageStats->{$group},
            maxDeductions => groupSetting($group, 'maxDeductionsInAssignment',
                                          $maxToolScore),
            deduction     => \$deduction,
            overLimit     => \$overLimit,
            fileName      => $fileName,
            violation     => $violation
       );

    # messageStats->file->filename->{num, collapse} (pts later)
    trackMessageInstanceInContext(
            context       => $messageStats->{file}->{$fileName},
            maxBeforeCollapsing =>
                markupSetting('maxBeforeCollapsing', 100000),
            maxDeductions =>
                markupSetting('maxDeductionsInAssignment', $maxToolScore),
            deduction     => \$deduction,
            overLimit     => \$overLimit,
            fileName      => $fileName,
            violation     => $violation
       );

    # messageStats->{num, collapse} (pts later)
    trackMessageInstanceInContext(
            context       => $messageStats,
            maxDeductions =>
                markupSetting('maxDeductionsInAssignment', $maxToolScore),
            deduction     => \$deduction,
            overLimit     => \$overLimit,
            fileName      => $fileName,
            violation     => $violation
       );

    # Recover overLimit in messageStats for collapsed rules
    if ($overLimit &&
        $messageStats->{$group}->{$rule}->{$fileName}->{collapse}->content)
    {
        $messageStats->{$group}->{$rule}->{$fileName}->{overLimit} = 1;
    }

    # Pts update in all locations:
    # ----------------------------
    #     messageStats->group->rule->filename->{pts}
    $messageStats->{$group}->{$rule}->{$fileName}->{pts} += $deduction;

    #     messageStats->group->rule->{pts}
    $messageStats->{$group}->{$rule}->{pts} += $deduction;

    #     messageStats->group->file->filename->{pts}
    $messageStats->{$group}->{file}->{$fileName}->{pts} += $deduction;

    #     messageStats->group->{pts}
    $messageStats->{$group}->{pts} += $deduction;

    #     messageStats->file->filename->{pts}
    $messageStats->{file}->{$fileName}->{pts} += $deduction;

    #     messageStats->{pts}
    $messageStats->{pts} += $deduction;

    # print "before: ", $violation->data_pointer(noheader  => 1,
    #                                           nometagen => 1);
    $violation->{deduction} = $deduction;
    $violation->{overLimit} = $overLimit;
    $violation->{group}     = $group;
    $violation->{category}  = ruleSetting($rule, 'category');
    $violation->{url}       = ruleSetting($rule, 'URL'     );
    if (!defined($codeMessages{$fileName}))
    {
        $codeMessages{$fileName} = {};
    }
    if (!defined($codeMessages{$fileName}{$violation->{line}->content}))
    {
        $codeMessages{$fileName}{$violation->{line}->content} = {};
    }
    if (!defined($codeMessages{$fileName}{$violation->{line}->content}{violations}))
    {
        $codeMessages{$fileName}{$violation->{line}->content}{violations} =
            [ $violation ];
    }
    else
    {
        push(@{ $codeMessages{$fileName}{$violation->{line}->content}{violations} },
            $violation);
    }
    # print "after: ", $violation->data_pointer(noheader  => 1,
    #                                          nometagen => 1);
    # print "messages for '$fileName' =\n\t",
    #     join("\n\t", @{ $messages{$fileName} }), "\n";
}


#-----------------------------------------------
# Some testing code left in place (but disabled  by the if test)
#
if (0)    # For testing purposes only
{
    # Some tests for properties
    # -------
    print "ShortVariable.group                     = ",
        ruleSetting('ShortVariable', 'group', 'zzz'), "\n";
    print "ShortVariable.deduction                 = ",
        ruleSetting('ShortVariable', 'deduction', 'zzz'), "\n";
    print "ShortVariable.category                  = ",
        ruleSetting('ShortVariable', 'category', 'zzz'), "\n";
    print "ShortVariable.maxBeforeCollapsing       = ",
        ruleSetting('ShortVariable', 'maxBeforeCollapsing', 'zzz'), "\n";
    print "ShortVariable.maxDeductionsInFile       = ",
        ruleSetting('ShortVariable', 'maxDeductionsInFile', 'zzz'), "\n";
    print "ShortVariable.maxDeductionsInAssignment = ",
      ruleSetting('ShortVariable', 'maxDeductionsInAssignment', 'zzz'), "\n";
    print "ShortVariable.URL                       = ",
        ruleSetting('ShortVariable', 'URL', 'zzz'), "\n";

    print "\n";
    print "naming.maxDeductionsInFile = ",
        groupSetting('naming', 'maxDeductionsInFile', 'zzz'), "\n";
    print "naming.maxDeductionsInAssignment = ",
        groupSetting('naming', 'maxDeductionsInAssignment', 'zzz'), "\n";
    print "naming.fooBar = ",
        groupSetting('naming', 'fooBar', 'zzz'), "\n";


    # Some tests for the messageStats structure
    # -------
    $messageStats->{naming}->{ShortVariable}->{num} = 1;
    $messageStats->{naming}->{ShortVariable}->{pts} = -1;
    $messageStats->{naming}->{ShortVariable}->{collapse} = 0;
    $messageStats->{documentation}->{JavaDocMethod}->{num} = 1;
    $messageStats->{documentation}->{JavaDocMethod}->{pts} = -1;
    $messageStats->{documentation}->{JavaDocMethod}->{collapse} = 0;
    print $messageStats->data(noheader  => 1, nometagen => 1);
    exit(0);
}


#-----------------------------------------------
# %codeMarkupIds is a map from file names to codeMarkup numbers
my $numCodeMarkups = $cfg->getProperty('numCodeMarkups', 0);
my %codeMarkupIds = ();

#-----------------------------------------------
# A useful subroutine for processing the ant log
if (!$buildFailed) # $can_proceed)
{
    my $checkstyleLog = "$resultDir/checkstyle_report.xml";
    if (-f $checkstyleLog)
    {
        my $cstyle = XML::Smart->new($checkstyleLog);
        foreach my $file (@{ $cstyle->{checkstyle}->{file} })
        {
            next if ($file->{name}->null);
            my $fileName = $file->{name}->content;
            $fileName =~ s,\\,/,go;
            $fileName =~ s,^\Q$workingDir/\E,,i;
            if (!defined $codeMarkupIds{$fileName})
            {
                $codeMarkupIds{$fileName} = ++$numCodeMarkups;
            }
            if (exists $file->{error})
            {
                foreach my $violation (@{ $file->{error} })
                {
                    my $rule = $violation->{source}->content;
                    $rule =~
                        s/^com\.puppycrawl\.tools\.checkstyle\.checks.*\.//o;
                    $rule =~ s/Check$//o;
                    $violation->{rule} = $rule;
                    delete $violation->{source};
                    trackMessageInstance(
                        $violation->{rule}->content, $fileName, $violation);
                }
            }
        }
    }

    my $pmdLog = "$resultDir/pmd_report.xml";
    if (-f $pmdLog)
    {
        my $pmd = XML::Smart->new($pmdLog);
        foreach my $file (@{ $pmd->{pmd}->{file} })
        {
            next if ($file->{name}->null);
            my $fileName = $file->{name}->content;
            $fileName =~ s,\\,/,go;
            $fileName =~ s,^\Q$workingDir/\E,,i;
            if (!defined $codeMarkupIds{$fileName})
            {
                $codeMarkupIds{$fileName} = ++$numCodeMarkups;
            }
            if (exists $file->{violation})
            {
                foreach my $violation (@{ $file->{violation} })
                {
                    trackMessageInstance(
                        $violation->{rule}->content, $fileName, $violation);
                }
            }
        }
    }

    if ($debug > 1)
    {
        my $msg = $messageStats->data(noheader  => 1, nometagen => 1);
        if (defined $msg)
        {
            print $msg;
        }
    }
    foreach my $f (keys %codeMessages)
    {
        print "$f:\n" if ($debug > 1);
        if ($messageStats->{file}->{$f}->{remarks}->null)
        {
            $messageStats->{file}->{$f}->{remarks} = 0;
        }
        my $codeMarkupNo = $codeMarkupIds{$f};
        foreach my $line (keys %{$codeMessages{$f}})
        {
            if (defined $codeMessages{$f}->{$line}{violations})
            {
        foreach my $v (@{ $codeMessages{$f}->{$line}{violations} })
        {
            if ($debug > 1)
            {
                print "\t", $v->{line}, ": -", $v->{deduction}, ": ",
                    $v->{rule}, " ol=", $v->{overLimit},
                    " kill=", $v->{kill}, "\n";
            }
            if ($messageStats->{ $v->{group} }->{ $v->{rule} }->{$f}
                ->{collapse}->content > 0)
            {
                if ($debug > 1)
                {
                    print "$f(", $v->{line}, "): -", $v->{deduction}, ": ",
                        $v->{rule}, ", collapsing\n";
                }
                if ($messageStats->{ $v->{group} }->{ $v->{rule} }->{$f}
                    ->{kill}->null())
                {
                    $v->{line} = 0;
                    if (!$v->{overLimit}->content &&
                        !$messageStats->{ $v->{group} }->{ $v->{rule} }->{$f}
                            ->{overLimit}->null)
                    {
                        $v->{overLimit} = 1;
                    }
                    $v->{deduction} =
                    $messageStats->{ $v->{group} }->{ $v->{rule} }->{$f}
                        ->{pts}->content;
                    $messageStats->{ $v->{group} }->{ $v->{rule} }->{$f}
                        ->{kill} = 1;
                }
                else
                {
                    $v->{kill} = 1;
                }
            }
            if ($v->{kill}->null)
            {
                $messageStats->{file}->{$f}->{remarks} =
                    $messageStats->{file}->{$f}->{remarks}->content + 1;
            }
        }
            }
            $cfg->setProperty("codeMarkup${codeMarkupNo}.deductions",
                (0 - $messageStats->{file}->{$f}->{pts}->content));
            $cfg->setProperty("codeMarkup${codeMarkupNo}.remarks",
                (0 + $messageStats->{file}->{$f}->{remarks}->content));
        }
    }
    $status{'toolDeductions'} = $messageStats->{pts}->content;
}
else
{
    $status{'toolDeductions'} = $maxToolScore;
}

# If no files were submitted at all, then no credit for static
# analysis
if (!$status{'studentHasSrcs'})
{
    $status{'toolDeductions'} = $maxToolScore;
}

# set PointsGained in Style section color the radial bar
if ($maxToolScore > 0)
{
    $styleSectionStatus{'pointsGainedPercent'} =
        (($maxToolScore - $status{'toolDeductions'})/$maxToolScore) * 100;
}
else
{
    $styleSectionStatus{'pointsGainedPercent'} = 100;
}


#=============================================================================
# translate html
#=============================================================================
my %coveredClasses     = ();
#my %classToFileNameMap = ();
#my %classToMarkupNoMap = ();
#my %fileToMarkupNoMap  = ();

#---------------------------------------------------------------------------
# Translate one HTML file from clover markup to what Web-CAT expects
sub translateHTMLFile
{
    my $file = shift;
    my $stripEmptyCoverage = shift;
    my $cloverData = shift;
    # print "translating $file\n";

    # Record class name
    my $className = $file;
    $className =~ s/\.html$//o;
    $className =~ s,^$resultDir/clover/(default-pkg/)?,,o;
    my $sourceName = $className . ".java";
    $className =~ s,/,.,go;
#    if (defined($classToFileNameMap{$className}))
#    {
#        $sourceName = $classToFileNameMap{$className};
#    }
    # print "class name = $className\n";
    $coveredClasses{$className} = 1;

    my @comments = ();
    if (defined $codeMessages{$sourceName})
    {
        foreach my $line (keys %{$codeMessages{$sourceName}})
        {
            if (defined $codeMessages{$sourceName}->{$line}{violations})
            {
                 @comments = (@comments,
                     @{ $codeMessages{$sourceName}->{$line}{violations} });
            }
        }
        @comments = sort { $b->{line}->content  <=>  $a->{line}->content }
            @comments;
    }
    $messageStats->{file}->{$sourceName}->{remarks} = countRemarks(\@comments);
#    if (defined($classToMarkupNoMap{$className}))
#    {
#        $cfg->setProperty('codeMarkup' . $classToMarkupNoMap{$className}
#                           . '.remarks',
#                $messageStats->{file}->{$sourceName}->{remarks}->content);
#    }
#    else
#    {
#       my $lcClassName = $className;
#       $lcClassName =~ tr/A-Z/a-z/;
#        if (defined($classToMarkupNoMap{$lcClassName}))
#        {
#            $cfg->setProperty('codeMarkup' . $classToMarkupNoMap{$lcClassName}
#                               . '.remarks',
#                    $messageStats->{file}->{$sourceName}->{remarks}->content);
#        }
#        else
#        {
#            print(STDERR "Cannot locate code markup number for $className "
#               . "in $sourceName\n");
#        }
#    }
    if ($debug > 1)
    {
        print "$sourceName: ", $#comments + 1, "\n";
        foreach my $c (@comments)
        {
            print "\t", $c->{group}, " '", $c->{line}, "'\n";
        }
    }

    open(HTML, $file) || die "Cannot open file for input '$file': $!";
    my @html = <HTML>;  # Slurp in the whole file
    close(HTML);
    my $allHtml = join("", @html);

    # Look for @author tags
    my @partnerExcludePatterns = ();
    my $partnerExcludePatterns_raw =
        $cfg->getProperty('grader.partnerExcludePatterns', "");
    if ($partnerExcludePatterns_raw ne "")
    {
        @partnerExcludePatterns =
            split(/(?<!\\),/, $partnerExcludePatterns_raw);
    }
    my $userName = $cfg->getProperty('userName', "");
    if ($userName ne "")
    {
        push(@partnerExcludePatterns, $userName);
    }
    my $potentialPartners = $cfg->getProperty('grader.potentialpartners', "");
    while ($allHtml =~
      m/<span[^<>]*class="javadoc"[^<>]*>\@author<\/span>\s*([^<>]*)<\/span>/g)
    {

        my $authors = $1;
        $authors =~ s/\@[a-zA-Z][a-zA-Z0-9\.]+[a-zA-Z]/ /g;
        $authors =~
        s/your-pid [\(]?and if in lab[,]? partner[']?s pid on same line[\)]?//;
        $authors =~ s/Partner [1-9][' ]?s name [\(]?pid[\)]?//;
        $authors =~ s/[,;:\(\)\]\]\{\}=!\@#%^&\*<>\/\\\`'"]/ /g;
        foreach my $pat (@partnerExcludePatterns)
        {
            $authors =~ s/(?<!\S)$pat(?!\S)//g;
        }
        $authors =~ s/^\s+//;
        $authors =~ s/\s+$//;
        $authors =~ s/\s\s+/ /g;
        if ($authors ne "")
        {
            if ($potentialPartners ne "")
            {
                $potentialPartners .= " ";
            }
            $potentialPartners .= $authors;
        }
    }
    $cfg->setProperty('grader.potentialpartners', $potentialPartners);

    # count the number of assertions that were not fully covered, in order
    # to remove them from the coverage stats
    my $preCount = $allHtml;
    my $conditionCount = ($preCount =~ s|(<tr>
        <td[^<>]*>[^<>]*</td>\s*<td[^<>]*\s+class=)"coverage(CountHilight">\s*)
        <a[^<>]*>([^<>]*)</a>
        (\s*</td>\s*<td[^<>]*>\s*<span\s+class="srcLine)
        Hilight(">\s*)<a[^<>]*>
        (\s*<span\s+class="keyword">assert</span>([^<>]\|<(/?)span[^<>]*>)*)
        \s*</a>
        |$1"line$2$3$4$5$6|ixsg);

    # Now, "unhighlight" all those that were only executed true (leave those
    # That were never executed at all marked, even though they won't be
    # counted against the student)
    my $executedConditionCount = ($allHtml =~ s|(<tr>
        <td[^<>]*>[^<>]*</td>\s*<td[^<>]*\s+class=)"coverage(CountHilight">\s*)
        <a[^<>]*>([^<>]*)</a>
        (\s*</td>\s*<td[^<>]*>\s*<span\s+class="srcLine)
        Hilight(">\s*)<a[^<>]*title="[^<>]*true\s[1-9][0-9]*\stime(s?),
        \sfalse\s0\stimes[^<>]*"[^<>]*>
        (\s*<span\s+class="keyword">assert</span>([^<>]\|<(/?)span[^<>]*>)*)
        \s*</a>
        |$1"line$2$3$4$5$7|ixsg);

    # Now, "unhighlight" all fail() method calls in test cases that weren't
    # executed.
    my $unexecutedFailCount = ($allHtml =~ s|(<tr>
        <td[^<>]*>[^<>]*</td>\s*<td[^<>]*\s+class=)"coverage(CountHilight">\s*)
        <a[^<>]*>([^<>]*)</a>
        (\s*</td>\s*<td[^<>]*>\s*<span\s+class="srcLine)
        Hilight(">\s*)<a[^<>]*title="[^<>]*never\sexecuted[^<>]*"[^<>]*>
        (\s*fail\s*\((<span [^<>]*>[^<>]*</span>)?\)\s*;)
        \s*</a>
        |$1"line$2$3$4$5$6|ixsg);

    # Now, "unhighlight" all the preventative null checks that were only
    # executed true
    my $executedNullCheckCount = ($allHtml =~ s|(<tr>
        <td[^<>]*>[^<>]*</td>\s*<td[^<>]*\s+class=)"coverage(CountHilight">\s*)
        <a[^<>]*>([^<>]*)</a>
        (\s*</td>\s*<td[^<>]*>\s*<span\s+class="srcLine)
        Hilight(">\s*)<a[^<>]*title="[^<>]*true\s[1-9][0-9]*\stime(s?),
        \sfalse\s0\stimes[^<>]*"[^<>]*>
        (((?!</a>)[^\?])*
        ([a-zA-Z_][a-zA-Z0-9_\.]*)\s*!=\s*
        <span\sclass="keyword">null</span>\s*\?
#        \s*\g{-1}\.[a-zA-Z_][a-zA-Z0-9_\.]*
        \s*[a-zA-Z_][a-zA-Z0-9_]*\.[a-zA-Z_][a-zA-Z0-9_\.]*
        \s*:\s*<span\sclass="keyword">null</span>
        ((?!</a>)[^\?])*)</a>
        |$1"line$2$3$4$5$7|ixsg);

    # Now, handle simple exception handlers, if needed.
    my $simpleCatchBlocks = 0;
    my $noViableAltBlocks = 0;
    if (!$requireSimpleExceptionCoverage)
    {
        $simpleCatchBlocks = ($allHtml =~ s|(<tr>
            ((?!</tr>).)*<span\sclass="keyword">catch</span>((?!</tr>).)*
            (</tr>\s*<tr>((?!</tr>).)*){((?!</tr>).)*</tr>\s*
            (<tr>((?!</tr>).)*<td\sclass="srcCell">\s*
                <span\s+class="srcLine">\s*
                    (<span\s+class="comment">((?!</span>).)*</span>\s*)?
                </span>\s*</td>\s*</tr>\s*)*
            <tr>\s*
            <td[^<>]*>[^<>]*</td>\s*<td[^<>]*\s+class=)"coverage
            (CountHilight">\s*)
            <a[^<>]*>([^<>]*)</a>
            (\s*</td>\s*<td[^<>]*>\s*<span\s+class="srcLine)
            Hilight(">\s*)<a[^<>]*title="[^<>]*never\sexecuted
            [^<>]*"[^<>]*>
            (\s*([a-zA-Z_][a-zA-Z0-9_]*\s*.\s*printStackTrace\s*\([^<>()]*\)\|
            <span\sclass="keyword">throw</span>\s+
            <span\sclass="keyword">new</span>\s+
            [A-Z][a-zA-Z0-9_]*\s*\([^<>()]*\)\|
            <span\sclass="keyword">return</span>\s+
            (?:[A-Za-z_][A-Za-z0-9_\.]+\|
            <span\sclass="string">"[^"]*"</span>)
            )\s*;)
            \s*</a>
            |$1"line$11$12$13$14$15|ixsg);

        $noViableAltBlocks += (
        #if (
        $allHtml =~ s|(<tr>
            ((?!</tr>).)*(?:<span\sclass="keyword">else</span>\s*{\|
            <span\sclass="keyword">default</span>\s*:)((?!</tr>).)*
            </tr>\s*<tr>\s*
            <td[^<>]*>[^<>]*</td>\s*<td[^<>]*\s+class=)"coverage
            (CountHilight">\s*)
            <a[^<>]*>([^<>]*)</a>
            (\s*</td>\s*<td[^<>]*>\s*<span\s+class="srcLine)
            Hilight(">\s*)<a[^<>]*title="[^<>]*never\sexecuted
            [^<>]*"[^<>]*>
            (\s*NoViableAltException\s+nvae\s+=)\s*</a>
            (((?!</tr>).)*</tr>\s*<tr>\s*((?!</tr>).)*
            <span\sclass="keyword">new</span>\s+NoViableAltException
            \([^\)]*\)\s*;
            ((?!</tr>).)*</tr>\s*<tr>\s*((?!</tr>).)*</tr>\s*<tr>\s*
            <td[^<>]*>[^<>]*</td>\s*<td[^<>]*\s+class=)"coverage
            (CountHilight">\s*)
            <a[^<>]*>([^<>]*)</a>
            (\s*</td>\s*<td[^<>]*>\s*<span\s+class="srcLine)
            Hilight(">\s*)<a[^<>]*title="[^<>]*never\sexecuted
            [^<>]*"[^<>]*>
            (\s*<span\sclass="keyword">throw</span>\s+nvae;)
            \s*</a>
            |$1"line$4$5$6$7$8$9"line$14$15$16$17$18|ixsg);
    }

    my $simpleGetters = 0;
    my $simpleSetters = 0;
    if (!$requireSimpleGetterSetterCoverage)
    {
        # First, handle 3-line getters
        $simpleGetters = ($allHtml =~ s|(<tr>((?!</tr>).)*
            <td[^<>]*\s+class=)"coverage
            (CountHilight">\s*)
            <a[^<>]*>([^<>]*)</a>
            (\s*</td>\s*<td[^<>]*>\s*<span\s+class="srcLine)
            Hilight(">\s*)<a[^<>]*title="[^<>]*method\snot\sentered
            [^<>]*"[^<>]*>
            (\s*<span\sclass="keyword">public</span>\s+
            (<span\sclass="keyword">[a-zA-Z]+</span>\|[A-Za-z][a-zA-Z0-9_]*)
            (?:\s*<[^<>]*>)?(?:\s*\[\s*\])*\s+
            (get[A-Z][a-zA-Z0-9_]*)\s*\(\s*\))(?:\s*</a>
            (((?!</tr>).)*</tr>\s*<tr>((?!</tr>).)*{)\|(\s*{)\s*</a>)
            (((?!</tr>).)*</tr>\s*<tr>\s*
            <td[^<>]*>[^<>]*</td>\s*<td[^<>]*\s+class=)"coverage
            (CountHilight">\s*)
            <a[^<>]*>([^<>]*)</a>
            (\s*</td>\s*<td[^<>]*>\s*<span\s+class="srcLine)
            Hilight(">\s*)<a[^<>]*title="[^<>]*never\sexecuted
            [^<>]*"[^<>]*>
            (\s*<span\sclass="keyword">return</span>\s+
            (?:[A-Za-z_][A-Za-z0-9_\.]+\|
            <span\sclass="string">"[^"]*"</span>\|
            <span\sclass="keyword">new</span>\s+
            [A-Z][a-zA-Z0-9_]*Parser\s*\[\]\s*{}
            );)\s*</a>
            ((((?!</tr>).)*</tr>\s*(<tr>((?!</tr>).)*))?
            })|$1"line$3$4$5$6$7$10$13$14"line$16$17$18$19$20$21|ixsg);

        # Now 1-line getters
        $simpleGetters += ($allHtml =~ s|(<tr>((?!</tr>).)*
            <td[^<>]*\s+class=)"coverage
            (CountHilight">\s*)
            <a[^<>]*>([^<>]*)</a>
            (\s*</td>\s*<td[^<>]*>\s*<span\s+class="srcLine)
            Hilight(">\s*)<a[^<>]*title="[^<>]*method\snot\sentered
            [^<>]*"[^<>]*>
            (\s*<span\sclass="keyword">public</span>\s+
            (<span\sclass="keyword">[a-zA-Z]+</span>\|[A-Za-z][a-zA-Z0-9_]*)
            (?:\s*<[^<>]*>)?(?:\s*\[\s*\])*\s+
            (get[A-Z][a-zA-Z0-9_]*)\s*\(\s*\)\s*{
            \s*<span\sclass="keyword">return</span>\s+
            (?:[A-Za-z_][A-Za-z0-9_\.]+\|
            <span\sclass="string">"[^"]*"</span>);\s*})\s*</a>
            |$1"line$3$4$5$6$7|ixsg);

        # Now 3-line setters
        $simpleSetters = ($allHtml =~ s|(<tr>((?!</tr>).)*
            <td[^<>]*\s+class=)"coverage
            (CountHilight">\s*)
            <a[^<>]*>([^<>]*)</a>
            (\s*</td>\s*<td[^<>]*>\s*<span\s+class="srcLine)
            Hilight(">\s*)<a[^<>]*title="[^<>]*method\snot\sentered
            [^<>]*"[^<>]*>
            (\s*<span\sclass="keyword">public</span>\s+
            <span\sclass="keyword">void</span>\s+
            (set[A-Z][a-zA-Z0-9_]*)\s*\(\s*
            (<span\sclass="keyword">[a-zA-Z]+</span>\|[A-Za-z][a-zA-Z0-9_]*)
            (?:\s*<[^<>]*>)?(?:\s*\[\s*\])*\s+
            [a-zA-Z_][a-zA-Z0-9_]*\s*\))
            (?:\s*</a>
            (((?!</tr>).)*</tr>\s*<tr>((?!</tr>).)*{)\|(\s*{)\s*</a>)
            (((?!</tr>).)*</tr>\s*<tr>\s*
            <td[^<>]*>[^<>]*</td>\s*<td[^<>]*\s+class=)"coverage
            (CountHilight">\s*)
            <a[^<>]*>([^<>]*)</a>
            (\s*</td>\s*<td[^<>]*>\s*<span\s+class="srcLine)
            Hilight(">\s*)<a[^<>]*title="[^<>]*never\sexecuted
            [^<>]*"[^<>]*>
            (\s*[A-Za-z_][A-Za-z0-9_\.]+\s*=\s*
            [A-Za-z_][A-Za-z0-9_]+;)\s*</a>
            ((((?!</tr>).)*</tr>\s*(<tr>((?!</tr>).)*))?
            })
            |$1"line$3$4$5$6$7$10$13$14"line$16$17$18$19$20$21|ixsg);

        # Now 1-line setters
        $simpleSetters += ($allHtml =~ s|(<tr>((?!</tr>).)*
            <td[^<>]*\s+class=)"coverage
            (CountHilight">\s*)
            <a[^<>]*>([^<>]*)</a>
            (\s*</td>\s*<td[^<>]*>\s*<span\s+class="srcLine)
            Hilight(">\s*)<a[^<>]*title="[^<>]*method\snot\sentered
            [^<>]*"[^<>]*>
            (\s*<span\sclass="keyword">public</span>\s+
            <span\sclass="keyword">void</span>\s+
            (set[A-Z][a-zA-Z0-9_]*)\s*\(\s*
            (<span\sclass="keyword">[a-zA-Z]+</span>\|[A-Za-z][a-zA-Z0-9_]*)
            (?:\s*<[^<>]*>)?(?:\s*\[\s*\])*\s+
            [a-zA-Z_][a-zA-Z0-9_]*\s*\)\s*{
            \s*[A-Za-z_][A-Za-z0-9_\.]+\s*=\s*
            [A-Za-z_][A-Za-z0-9_]+;\s*})\s*</a>
            |$1"line$3$4$5$6$7|ixsg);
    }

    if ($debug)
    {
        print "\tFound $conditionCount uncovered assertions, with ",
            "$executedConditionCount partially executed.\n";
        print "\tFound $unexecutedFailCount unexecuted fail() statements.\n";
        print "\tFound $simpleCatchBlocks simple catch blocks.\n";
        print "\tFound $simpleGetters simple getters.\n";
        print "\tFound $simpleSetters simple setters.\n";
        print "\tFound $noViableAltBlocks NoViableAltException blocks.\n";
    }

    if ($conditionCount || $unexecutedFailCount || $simpleCatchBlocks
        || $simpleGetters || $simpleSetters || $executedNullCheckCount
        || $noViableAltBlocks)
    {
        if ($debug)
        {
            print $cloverData->data, "\n";
        }
        $cloverData->{coverage}{project}{metrics}{conditionals} -=
            2 * $conditionCount;
        $cloverData->{coverage}{project}{metrics}{coveredconditionals} -=
            $executedConditionCount;
        $cloverData->{coverage}{project}{metrics}{elements} -=
            2 * $conditionCount;
        $cloverData->{coverage}{project}{metrics}{coveredelements} -=
            $executedConditionCount;

        $cloverData->{coverage}{project}{metrics}{conditionals} -=
            2 * $executedNullCheckCount;
        $cloverData->{coverage}{project}{metrics}{coveredconditionals} -=
            $executedNullCheckCount;
        $cloverData->{coverage}{project}{metrics}{elements} -=
            2 * $executedNullCheckCount;
        $cloverData->{coverage}{project}{metrics}{coveredelements} -=
            $executedNullCheckCount;

        $cloverData->{coverage}{project}{metrics}{elements} -=
            $unexecutedFailCount + 2 * $noViableAltBlocks;
        $cloverData->{coverage}{project}{metrics}{statements} -=
            $unexecutedFailCount + 2 * $noViableAltBlocks;

        $cloverData->{coverage}{project}{metrics}{elements} -=
            $simpleCatchBlocks;
        $cloverData->{coverage}{project}{metrics}{statements} -=
            $simpleCatchBlocks;

        $cloverData->{coverage}{project}{metrics}{elements} -=
            2 * ($simpleGetters + $simpleSetters);
        $cloverData->{coverage}{project}{metrics}{methods} -=
            $simpleGetters + $simpleSetters;
        $cloverData->{coverage}{project}{metrics}{statements} -=
            $simpleGetters + $simpleSetters;

        foreach my $pkg (@{ $cloverData->{coverage}{project}{package} })
        {
            foreach my $file (@{ $pkg->{file} })
            {
                my $fileName = $file->{name}->content;
                if ($debug)
                {
                    print "    clover patch: checking $fileName against ",
                        "$sourceName\n";
                }
                $fileName =~ s,\\,/,go;
                my $Uprojdir = $workingDir . "/";
                $fileName =~ s/^\Q$Uprojdir\E//io;
                print "    ... pruned file name = $fileName\n" if ($debug);
                if ($fileName eq $sourceName)
                {
                    print "    ... clover element found!\n" if ($debug);
                    $file->{metrics}{conditionals} -= 2 * $conditionCount;
                    $file->{metrics}{coveredconditionals} -=
                        $executedConditionCount;
                    $file->{metrics}{elements} -= 2 * $conditionCount;
                    $file->{metrics}{coveredelements} -=
                        $executedConditionCount;

                    $file->{metrics}{elements} -=
                        $unexecutedFailCount + 2 * $noViableAltBlocks;
                    $file->{metrics}{statements} -=
                        $unexecutedFailCount + 2 * $noViableAltBlocks;

                    $file->{metrics}{elements} -= $simpleCatchBlocks;
                    $file->{metrics}{statements} -= $simpleCatchBlocks;

                    $file->{metrics}{elements} -=
                        2 * ($simpleGetters + $simpleSetters);
                    $file->{metrics}{methods} -=
                        $simpleGetters + $simpleSetters;
                    $file->{metrics}{statements} -=
                        $simpleGetters + $simpleSetters;
                }
            }
        }
        if ($debug)
        {
            print "\nafter correction:\n";
            print $cloverData->data;
            print "\n";
        }
    }

    my $reformatter = new Web_CAT::Clover::Reformatter(
        \@comments, $stripEmptyCoverage, $allHtml);
    $reformatter->save($file);
}


#---------------------------------------------------------------------------
# Walk a dir, deleting unneeded clover-generated files and translating others
sub processCloverDir
{
    my $path = shift;
    my $stripEmptyCoverage = shift;
    my $cloverData = shift;

    # print "processing $path, strip = $stripEmptyCoverage\n";

    if (-d $path)
    {
        for my $file (bsd_glob("$path/*"))
        {
            processCloverDir($file, $stripEmptyCoverage, $cloverData);
        }

        # is the dir empty now?
        my @files = bsd_glob("$path/*");
        if ($#files < 0)
        {
            # print "deleting empty dir $path\n";
            if (!rmdir($path))
            {
                adminLog("cannot delete empty directory '$path': $!");
            }
        }
    }
    elsif ($path !~ m/\.html$/io || $path =~
    m/(^|\/)(all-classes|all-pkgs|index|pkg-classes|pkg(s?)-summary)\.html$/io)
    {
        # print "deleting $path\n";
        if (unlink($path) != 1)
        {
            adminLog("cannot delete file '$path': $!");
        }
    }
    else
    {
        # An HTML file to keep!
        translateHTMLFile($path, $stripEmptyCoverage, $cloverData);
    }
}


my $time5 = time;
if ($debug)
{
    print "\n", ($time5 - $time4), " seconds\n";
}


#=============================================================================
# convert clover.xml to properties (and record html files)
#=============================================================================
my $gradedElements        = 0;
my $gradedElementsCovered = 0;
my $runtimeScoreWithoutCoverage = 0;
if (defined $status{'instrTestResults'} && $status{'studentHasSrcs'})
{
    if ($status{'compileErrs'})
    {
        # If there was a compilation error, don't count any instructor
        # tests as passed to force an "unknown" result
        $status{'instrTestResults'}->addTestsExecuted(
            -$status{'instrTestResults'}->testsExecuted);
    }
    $runtimeScoreWithoutCoverage =
        $maxCorrectnessScore * $status{'instrTestResults'}->testPassRate;
}

print "score with ref tests: $runtimeScoreWithoutCoverage\n" if ($debug > 2);

if (defined $status{'studentTestResults'}
    && $status{'studentTestResults'}->testsExecuted > 0)
{
    if ($studentsMustSubmitTests)
    {
        if ($allStudentTestsMustPass
            && $status{'studentTestResults'}->testsFailed > 0)
        {
            $runtimeScoreWithoutCoverage = 0;
        }
        else
        {
            $runtimeScoreWithoutCoverage *=
                $status{'studentTestResults'}->testPassRate;
        }
    }
    $studentCasesPercent =
        int($status{'studentTestResults'}->testPassRate * 100.0 + 0.5);
    if ($status{'studentTestResults'}->testsFailed > 0
        && $studentCasesPercent == 100)
    {
        # Don't show 100% if some cases failed
        $studentCasesPercent--;
    }
}
elsif ($studentsMustSubmitTests)
{
    $runtimeScoreWithoutCoverage = 0;
}

print "score with student tests: $runtimeScoreWithoutCoverage\n"
    if ($debug > 2);


#=============================================================================
# Scan source file(s) to find code where coverage isn't required
#=============================================================================
my @partnerExcludePatterns = ();
my $partnerExcludePatterns_raw =
    $cfg->getProperty('grader.partnerExcludePatterns', '');
if ($partnerExcludePatterns_raw ne '')
{
    @partnerExcludePatterns = split(/(?<!\\),/, $partnerExcludePatterns_raw);
}
my $userName = $cfg->getProperty('userName', '');
if ($userName ne '')
{
    push(@partnerExcludePatterns, $userName);
}
my $potentialPartners = $cfg->getProperty('grader.potentialpartners', '');

sub extractExemptLines
{
    my $fileName    = shift;
    my $exemptLines = shift;

    if (-d $fileName)
    {
        foreach my $f (bsd_glob("$fileName/*"))
        {
            extractExemptLines($f, $exemptLines);
        }
    }
    elsif ($fileName =~ m/\.java$/io)
    {
        if (open(SRCFILE, $fileName))
        {
            my @lines = <SRCFILE>;
            close(SRCFILE);
                @lines = map {
                    $_ =~ s/\r\n/\n/go;
                    $_ =~ s/\r/\r\n/go;
                    map { $_ =~ s/\r//go; $_ } split(/(?<=\r\n)/, $_)
                } @lines;
            my $fullText = join('', @lines);

            # Look for @author tags
            while ($fullText =~ m/^[\s\*]*\@author\s*(.*)$/gmo)
            {
                my $authors = $1;
                $authors =~ s/\@[a-zA-Z][a-zA-Z0-9\.]+[a-zA-Z]/ /g;
                $authors =~
        s/your-pid [\(]?and if in lab[,]? partner[']?s pid on same line[\)]?//;
                $authors =~ s/Partner [1-9][' ]?s name [\(]?pid[\)]?//;
                $authors =~ s/[,;:\(\)\]\]\{\}=!\@#%^&\*<>\/\\\`'"]/ /g;
                foreach my $pat (@partnerExcludePatterns)
                {
                    $authors =~ s/(?<!\S)$pat(?!\S)//g;
                }
                $authors =~ s/^\s+//;
                $authors =~ s/\s+$//;
                $authors =~ s/\s\s+/ /g;
                if ($authors ne '')
                {
                    if ($potentialPartners ne '')
                    {
                        $potentialPartners .= ' ';
                    }
                    $potentialPartners .= $authors;
                }
            }
            $cfg->setProperty('grader.potentialpartners', $potentialPartners);


            if (! defined $exemptLines->{$fileName})
            {
                $exemptLines->{$fileName} = {};
            }

            my $simpleGetters = 0;
            my $simpleSetters = 0;
            if (!$requireSimpleGetterSetterCoverage)
            {
                # First, handle getters
                while ($fullText =~ m/((?<=\n)[^\S\n]*)
                    ((public|protected)?\s+
                    ([a-zA-Z]+|[A-Za-z][a-zA-Z0-9_]*)
                    (?:\s*\[\s*\])*\s+
                    (get[A-Z][a-zA-Z0-9_]*)\s*\(\s*\)
                    \s*{\s*
                    return\s+
                    (?:[A-Za-z_][A-Za-z0-9_\.]*|
                    "[^"]*"|
                    new\s+[A-Z][a-zA-Z0-9_]*Parser\s*\[\]\s*{}
                    );\s*}
                    )/ixsg)
                {
                    my $pre = $`;
                    my $getter = $2;
                    my $line1 = ($pre =~ tr/\n//) + 1;
                    my $lines = ($getter =~ tr/\n//) + 1;
                    if (!defined $exemptLines->{$fileName}->{method})
                    {
                        $exemptLines->{$fileName}->{method} = [];
                    }
                    push(@{$exemptLines->{$fileName}->{method}},
                        [$line1, $line1 + $lines - 1, 0]);
                    for (my $i = $line1; $i < $line1 + $lines; $i++)
                    {
                        $exemptLines->{$fileName}->{$i} = -1;
                    }
                }

                # Now setters
                while ($fullText =~ m/((?<=\n)[^\S\n]*)
                    ((public|protected)?\s+void\s+
                    (set[A-Z][a-zA-Z0-9_]*)\s*\(\s*
                    ([a-zA-Z]+|[A-Za-z][a-zA-Z0-9_]*)\s*
                        [a-zA-Z_][a-zA-Z0-9_]*\s*\)
                    \s*{\s*
                    [A-Za-z_][A-Za-z0-9_\.]*\s*=\s*[A-Za-z_][A-Za-z0-9_]*;
                    \s*})/ixsg)
                {
                    my $pre = $`;
                    my $setter = $2;
                    my $line1 = ($pre =~ tr/\n//) + 1;
                    my $lines = ($setter =~ tr/\n//) + 1;
                    # print "found setter: $setter\n";
                    # print " start line = $line1; lines = $lines\n";
                    if (!defined $exemptLines->{$fileName}->{method})
                    {
                        $exemptLines->{$fileName}->{method} = [];
                    }
                    push(@{$exemptLines->{$fileName}->{method}},
                        [$line1, $line1 + $lines - 1, 0]);
                    for (my $i = $line1; $i < $line1 + $lines; $i++)
                    {
                        $exemptLines->{$fileName}->{$i} = -1;
                    }
                }
            }

            # Now, handle simple exception handlers, if needed.
            my $simpleCatchBlocks = 0;
            my $noViableAltBlocks = 0;
            if (!$requireSimpleExceptionCoverage)
            {
                while ($fullText =~ m/((?<=\n)(?:[^\S\n]|\/\/[^\n]*)*
                    (}(?:[^\S\n]|\/\/[^\n]*)*)?)
                    (catch([\s\n]|\/\/[^\n]*)*
                    \(\s*[A-Z][a-zA-Z0-9_]*(\s*\|
                      \s*[a-zA-Z_][a-zA-Z0-9_]*)*
                      \s*[a-zA-Z_][a-zA-Z0-9_]*\s*\)
                    [\s\n]*{([\s\n]|\/\/[^\n]*)*
                    (([a-zA-Z_][a-zA-Z0-9_]*\s*\.\s*
                     printStackTrace\s*\([^()]*\)|
                     throw\s+new\s+
                     [A-Z][a-zA-Z0-9_]*\s*\([^()]*\)|
                     return\s*[^;}]*
                    )\s*;)([\s\n]|\/\/[^\n]*)*})
                    /ixsg)
                {
                    my $pre = $`;
                    my $handler = $3;
                    my $line1 = ($pre =~ tr/\n//) + 1;
                    my $lines = ($handler =~ tr/\n//) + 1;
                    # print "found handler: $handler\n";
                    # print " start line = $line1; lines = $lines\n";
                    for (my $i = $line1; $i < $line1 + $lines; $i++)
                    {
                        $exemptLines->{$fileName}->{$i} = -1;
                    }
                }
            }

            # sort method entries
            if (defined $exemptLines->{$fileName}->{method})
            {
                @{$exemptLines->{$fileName}->{method}} =
                    sort { $a->[0] <=> $b->[0] }
                        @{$exemptLines->{$fileName}->{method}};
            }
        }
    }
    else
    {
        print "Cannot open source file $fileName: $!\n";
    }

    return $exemptLines;
}


#=============================================================================
# post-process generated HTML files
#=============================================================================
my $jacoco  = (-f "$resultDir/jacoco.xml")
    ? XML::Smart->new("$resultDir/jacoco.xml")
    : undef;

#if (!$buildFailed) # $can_proceed)
#{
#    # Figure out mapping from class names to file names
#    my $Uprojdir = $workingDir . "/";
#    foreach my $pkg (@{ $jacoco->{report}{package} })
#    {
#        my $pkgName = $pkg->{name}->content;
#        print "package: ", $pkg->{name}->content, "\n";
#        if ($pkgName ne '')
#        {
#            $pkgName =~ s,\\,/,go;
#            $pkgName .= '/';
#        }
#        foreach my $file (@{ $pkg->{sourcefile} })
#        {
#            my $fileName = $pkgName . $file->{name}->content;
##            $classToFileNameMap{$fqClassName} = $fileName;
#             print "\tfile: $fileName\n";
#        }
#    }
#    $buildFailed = 1;
#
#    # Delete unneeded files from the clover/ html dir
#    if (-d "$resultDir/clover")
#    {
#        processCloverDir("$resultDir/clover",
#            !defined($status{'studentTestResults'})
#                || !$status{'studentTestResults'}->hasResults
#                || !$status{'studentTestResults'}->testsExecuted,
#            $jacoco);
#    }

    # If any classes in the default package, move them to correct place
#    my $defPkgDir = "$resultDir/clover/default-pkg";
#    if (-d $defPkgDir)
#    {
#        for my $file (bsd_glob("$defPkgDir/*"))
#        {
#            my $newLoc = $file;
#            if ($newLoc =~ s,/default-pkg/,/,o)
#            {
#                rename($file, $newLoc);
#            }
#        }
#        if (!rmdir($defPkgDir))
#        {
#            adminLog("cannot delete empty directory '$defPkgDir': $!");
#        }
#    }
#
#    if ($debug > 1)
#    {
#        print "Clover'ed classes (from HTML):\n";
#        foreach my $class (keys %coveredClasses)
#        {
#            print "\t$class\n";
#        }
#        print "\n";
#    }
#}

my $time6 = time;
if ($debug)
{
    print "\n", ($time6 - $time5), " seconds\n";
}

# Compute FileName of the Class (even for inner level classes)
sub computeFileNameUsingClassName
{
    my $className = shift;

    # If the className is outer level class (fileName); it will be found in
    # the keys of codeMarkupIds.
    for my $longName (keys %codeMarkupIds)
    {
        if (index(lc($longName), lc($className . '.java')) != -1)
        {
            return $longName;
        }
    }

    # Parse each file and see which file contains that class.
    # pattern we are looking for is "class $className "
    for my $longName (keys %codeMarkupIds)
    {
        if (checkForPatternInFile($longName, 'class' . ' ' .$className. ' '))
        {
            return $longName;
        }
    }

    return;
}

# contains $filename . $lineNum as the key, these statements are displayed
# as uncovered statements under methods uncovered, so we ignore them for
# statements and branches uncovered
my %fileLineNumMethodUncovered;

#Contains the beginLine of each method (tests also).
my %methodBeginLineNum;


sub addMethodBeginLineNum
{
    # This data is obtained from JaCoCo
    my $class = shift;

    foreach my $method (@{ $class->{method} })
    {
        $methodBeginLineNum{$method->{name}} = $method->{line};
    }
}


# Computes Uncovered Methods in a class and adds to the temporary
# perFileRuleStruct Hash
sub computeMethodsUncovered
{
    my $class = shift;

    my $fileName = computeFileNameUsingClassName($class->{name}->content);

    foreach my $method (@{ $class->{method} })
    {
        my $counter = $method->{counter}('type', 'eq', 'INSTRUCTION');

        # print($method->{name}->content);
        # print "\n";
        if ($counter->{covered}->content != 0)
        {
            next;
        }

        my $numLines =
            $method->{counter}('type', 'eq', 'LINE')->{missed}->content;
        # Add the lines in the method uncovered to the hash
        addTofileLineMethodUncoveredHash(
            $fileName, $method->{line}->content, $numLines);

        # Jacoco gives the line number of the body of the method: so we
        # do "-2" to the line number
        my $methodCoverageStruct = generateCompleteErrorStruct(
            $fileName, $method->{line}->content-2,
            'Method not executed',
            'This method or constructor was not executed by any of your '
            . 'software tests. Add more tests to check its behavior.');

        # Insert into the temporary hash with key as concatenation of fileName
        # and methodName.
        # Count would be the number of missed instructions (later we
        # sort(desc) based on that).
        $perFileRuleStruct{'methodsUncovered'}{'count'}{$fileName . $method->{name}->content} =
            $counter->{missed}->content;

        $perFileRuleStruct{'methodsUncovered'}{'data'}{$fileName . $method->{name}->content} =
            $methodCoverageStruct;
    }
}

# Compute Brances Uncovered and add to perFileRuleStruct
sub computeBranchesUncovered
{
    my $lineNum = shift;
    my $missedBranches = shift;
    my $fileName = shift;
    my $message = shift;

    # This statement is covered under "uncovered methods"
    if (defined $fileLineNumMethodUncovered{$fileName . $lineNum})
    {
        return;
    }

    if ($message !~ m/\.$/o) { $message .= '.'; }
    my $branchCoverageStruct = generateCompleteErrorStruct(
        $fileName, $lineNum, 'Condition not executed', $message);

    # Insert into the temporary hash with key as concatenation of fileName and
    # line number.
    # Count would be the number of missed branches (later we sort(desc)
    # based on that).
    $perFileRuleStruct{'conditionsUncovered'}{'count'}{$fileName . $lineNum} =
        $missedBranches;

    $perFileRuleStruct{'conditionsUncovered'}{'data'}{$fileName . $lineNum} =
        $branchCoverageStruct;
}

# Temporary used only for Statements Coverage
# filename----line numbers
my %perFileStatementUncovered;

sub addTofileLineMethodUncoveredHash
{
    my $fileName = shift;
    my $beginLine = shift;
    my $numLines = shift;

    my $endLine = $beginLine + $numLines - 1;

    while ($beginLine <= $endLine)
    {
        $fileLineNumMethodUncovered{$fileName . $beginLine} = 1;
        $beginLine++;
    }
}

# Compute All the statements that are uncovered to add to the temporary hash
sub computeStatementsUncovered
{
    my $lineNum = shift;
    my $fileName = shift;

    # This statement is covered under "uncovered methods"
    if (defined $fileLineNumMethodUncovered{$fileName . $lineNum})
    {
        return;
    }

    if (defined $perFileStatementUncovered{$fileName})
    {
        push @{$perFileStatementUncovered{$fileName}}, $lineNum;
    }
    else
    {
        my @temp;
        push @temp, $lineNum;
        $perFileStatementUncovered{$fileName} = [@temp];
    }
}

# generate the error struct for statement coverage
sub generateStatementsUncoveredErrorStruct
{
    my $fileName = shift;
    my $startLineNum = shift;
    my $endLineNum = shift;
    my $errorMessage = shift;

    my $codeLines = '';

    # The line above the beginning of the uncovered statement.
    $codeLines .=
        extractLineOfCode($fileName, $startLineNum - 1);

    # If the block contains less than or equal to 8 statements then
    # show all of them
    if ($endLineNum - $startLineNum <= 7)
    {
        my $tempStartLineNum = $startLineNum;
        while ($tempStartLineNum <= $endLineNum)
        {
            $codeLines .= extractLineOfCode($fileName, $tempStartLineNum);
            $tempStartLineNum++;
        }
    }
    else
    {
        my $tempStartLineNum = $startLineNum;

        # First four uncovered statements
        while ($tempStartLineNum <= $startLineNum+3)
        {
            $codeLines .= extractLineOfCode($fileName, $tempStartLineNum);
            $tempStartLineNum++;
        }

        $codeLines .= '...';
        $codeLines .= "\n";

        #Last four uncovered statements
        $tempStartLineNum = $endLineNum - 3;
        while ($tempStartLineNum <= $endLineNum)
        {
            $codeLines .= extractLineOfCode($fileName, $tempStartLineNum);
            $tempStartLineNum++;
        }
    }

    # The line after the end of the uncovered statements.
    $codeLines .=
        extractLineOfCode($fileName, $endLineNum + 1);

    my $errorStruct = expandedMessage->new(
        entityName => $fileName,
        lineNum => $startLineNum,
        errorMessage => 'Statements not executed',
        linesOfCode => $codeLines,
        enhancedMessage => $errorMessage,
        );

    return $errorStruct;
}

sub processStatementsUncovered
{
    foreach my $key (keys % perFileStatementUncovered)
    {
        my @lineNums = @{$perFileStatementUncovered{$key}};
        @lineNums = sort @lineNums;

        my $startLineNum = -1;
        my $endLineNum = -1;

        for my $lineNum (@lineNums)
        {
            if ($startLineNum == -1)
            {
                $startLineNum = $lineNum;
                $endLineNum = $lineNum;
                next;
            }

            if ($endLineNum+1 == $lineNum)
            {
                $endLineNum = $lineNum;
            }
            else
            {
                my $statementCoverageStruct =
                    generateStatementsUncoveredErrorStruct(
                    $key, $startLineNum, $endLineNum,
                    'These statements were not executed by your tests.');

                # Insert into the temporary hash with key as concatenation of
                # fileName and start line number.
                # Count would be the number of missed statements (later we
                # sort(desc) based on that).
                $perFileRuleStruct{'statementsUncovered'}{'count'}{$key . $startLineNum} =
                    $endLineNum - $startLineNum + 1;

                $perFileRuleStruct{'statementsUncovered'}{'data'}{$key . $startLineNum} =
                    $statementCoverageStruct;

                $startLineNum = $lineNum;
                $endLineNum = $lineNum;
            }

        }

        if ($startLineNum != -1)
        {
            my $statementCoverageStruct =
                generateStatementsUncoveredErrorStruct(
                  $key, $startLineNum, $endLineNum,
                  'These statements were not executed by your tests.');

            # Insert into the temporary hash with key as concatenation of
            # fileName and start line number
            # Count would be the number of missed statements (later we
            # sort(desc) based on that).
            $perFileRuleStruct{'statementsUncovered'}{'count'}{$key . $startLineNum} =
                $endLineNum - $startLineNum + 1;

            $perFileRuleStruct{'statementsUncovered'}{'data'}{$key . $startLineNum} =
                $statementCoverageStruct;
        }
    }
}

if (!$buildFailed) # $can_proceed)
{
    if (defined $jacoco)
    {
    my $counter = $jacoco->{report}{counter}('type', 'eq', 'METHOD');
    my $methods = 0 + $counter->{missed}->content
        + $counter->{covered}->content;
    my $methodsCovered = 0 + $counter->{covered}->content;
    my $lines = 0;
    my $linesCovered = 0;
    my $instructions = 0;
    my $instructionsCovered = 0;
    my $complexity = 0;
    my $complexityCovered = 0;
    my $branches = 0;
    my $branchesCovered = 0;

        my @suiteNodes = ();
        for my $pkg (@{$jacoco->{report}{package}})
        {
            my $pkgName = $pkg->{name};
            $pkgName =~ s,/,.,go;
            print "package = " . $pkg->{name} . " ($pkgName)\n" if ($debug > 3);
            for my $cls (@{$pkg->{class}})
            {
                my $clsName = $cls->{name};
                $clsName =~ s,^.*/([^/]+)$,\1,o;
                print "    class = " . $cls->{name} . " ($clsName)\n"
                    if ($debug > 3);
                if (defined $suites{$pkgName}
                    && defined $suites{$pkgName}->{$clsName})
                {
                    push(@suiteNodes, $cls);
                    print "        suite found\n" if ($debug > 3);

                    if ($includeTestSuitesInCoverage)
                    {
                        computeMethodsUncovered($cls);
                    }
                }
                else
                {
                    computeMethodsUncovered($cls);
                }
                addMethodBeginLineNum($cls);
            }
        }

        # Initialize counter based on top-level accumulators in jacoco.xml
        $counter = $jacoco->{report}{counter}('type', 'eq', 'LINE');
        $lines += 0 + $counter->{missed}->content
            + $counter->{covered}->content;
        $linesCovered += 0 + $counter->{covered}->content;
        $counter = $jacoco->{report}{counter}('type', 'eq', 'INSTRUCTION');
        $instructions += 0 + $counter->{missed}->content
            + $counter->{covered}->content;
        $instructionsCovered += 0 + $counter->{covered}->content;
        $counter = $jacoco->{report}{counter}('type', 'eq', 'COMPLEXITY');
        $complexity += 0 + $counter->{missed}->content
            + $counter->{covered}->content;
        $complexityCovered += 0 + $counter->{covered}->content;
        $counter = $jacoco->{report}{counter}('type', 'eq', 'BRANCH');
        $branches += 0 + $counter->{missed}->content
            + $counter->{covered}->content;
        $branchesCovered += 0 + $counter->{covered}->content;
        if (!$includeTestSuitesInCoverage)
        {
            for my $cls (@suiteNodes)
            {
                $counter = $cls->{counter}('type', 'eq', 'LINE');
                $lines -= 0 + $counter->{missed}->content
                    + $counter->{covered}->content;
                $linesCovered -= 0 + $counter->{covered}->content;
                $counter = $cls->{counter}('type', 'eq', 'INSTRUCTION');
                $instructions -= 0 + $counter->{missed}->content
                    + $counter->{covered}->content;
                $instructionsCovered -= 0 + $counter->{covered}->content;
                $counter = $cls->{counter}('type', 'eq', 'COMPLEXITY');
                $complexity -= 0 + $counter->{missed}->content
                    + $counter->{covered}->content;
                $complexityCovered -= 0 + $counter->{covered}->content;
                $counter = $cls->{counter}('type', 'eq', 'BRANCH');
                $branches -= 0 + $counter->{missed}->content
                    + $counter->{covered}->content;
                $branchesCovered -= 0 + $counter->{covered}->content;
                $counter = $cls->{counter}('type', 'eq', 'METHOD');
                $methods -= 0 + $counter->{missed}->content
                    + $counter->{covered}->content;
                $methodsCovered -= 0 + $counter->{covered}->content;
            }
        }

    my $Uprojdir = $workingDir . "/";
    my %exemptLines = ();
    my %fileDeductionProperties = ();
    foreach my $pkg (@{ $jacoco->{report}{package} })
    {
        my $pkgName = $pkg->{name}->content;
        # print "package: ", $pkg->{name}->content, "\n";
        if ($pkgName ne '')
        {
            $pkgName =~ s,\\,/,go;
            $pkgName .= '/';
        }
        my $javaPackageName = $pkg->{name}->content;
        $javaPackageName =~ s,[/\\],.,go;
        foreach my $file (@{ $pkg->{sourcefile} })
        {
            my $fileName = $pkgName . $file->{name}->content;

            my $className = $file->{name}->content;
            $className =~ s,\..*$,,o;
            # print "\tclass: ", $file->{class}->{name}->content, "\n";
            my $fqClassName = $fileName;
            $fqClassName =~ s,\..*$,,o;
            $fqClassName =~ s,/,.,go;
            my $includeCvg = $includeTestSuitesInCoverage
                || !(defined $suites{$javaPackageName})
                || !(defined $suites{$javaPackageName}->{$className});

            # Try to match against longer file names from checkstyle/pmd
            my $bestMatch = undef;
            for my $longName (keys %codeMarkupIds)
            {
                if ($longName =~ m,/\Q$fileName\E$,)
                {
                    if (!defined $bestMatch
                        || length($longName) < length($bestMatch))
                    {
                        $bestMatch = $longName;
                    }
                }
            }
            if (defined $bestMatch)
            {
                $fileName = $bestMatch;
            }

            my $codeMarkupNo;
            if (defined $codeMarkupIds{$fileName})
            {
                $codeMarkupNo = $codeMarkupIds{$fileName};
            }
            else
            {
                $codeMarkupNo = ++$numCodeMarkups;
                $codeMarkupIds{$fileName} = $codeMarkupNo;
            }

            # Identify lines that don't require coverage
            my %exemptLines = ();
            extractExemptLines($fileName, \%exemptLines);
            if ($debug > 3)
            {
                print "exempt lines = ", dump(\%exemptLines), "\n";
            }

            # Save coverage data to %codeMessages
            if (!defined $codeMessages{$fileName})
            {
                $codeMessages{$fileName} = {};
            }
            my $msgs = $codeMessages{$fileName};
            my $exemptLinesCovered = 0;
            my $exemptLinesMissed = 0;
            my $exemptInstructionsCovered = 0;
            my $exemptInstructionsMissed = 0;
            my $exemptMethodsCovered = 0;
            my $exemptMethodsMissed = 0;
            my $exemptBranchesCovered = 0;
            my $exemptBranchesMissed = 0;
            my $exemptComplexityCovered = 0;
            my $exemptComplexityMissed = 0;
            foreach my $line (@{ $file->{line} })
            {

                my $num = 0 + $line->{nr}->content;
                my $ci = 0 + $line->{ci}->content;
                my $mi = 0 + $line->{mi}->content;
                my $cb = 0 + $line->{cb}->content;
                my $mb = 0 + $line->{mb}->content;
                if (defined $exemptLines{$fileName})
                {
                     if (defined $exemptLines{$fileName}->{$num})
                     {
                         if ($ci + $mi + $cb + $mb > 0)
                         {
                             if ($ci + $cb > 0)
                             {
                                 $exemptLinesCovered++;
                             }
                             elsif ($mi + $mb > 0)
                             {
                                 $exemptLinesMissed++;
                             }
                             $exemptInstructionsCovered += $ci;
                             $exemptInstructionsMissed += $mi;
                             $exemptBranchesCovered += $cb;
                             $exemptBranchesMissed += $mb;
                             $exemptComplexityCovered += $cb / 2;
                             $exemptComplexityMissed +=
                                 ($mb + $cb) / 2 - ($cb / 2);
                             if (defined $exemptLines{$fileName}->{method})
                             {
                                 for my $methodRange (
                                  @{$exemptLines{$fileName}->{method}})
                                 {
                                     if ($methodRange->[0] <= $num
                                         && $methodRange->[1] >= $num)
                                     {
                                         if ($ci + $cb > 0)
                                         {
                                             $methodRange->[2]++;
                                         }
                                         last;
                                     }
                                     elsif ($methodRange->[0] > $num)
                                     {
                                         last;
                                     }
                                 }
                             }
                         }
                         next;
                     }
                }
                if ($mb)
                {

                    if (!defined $msgs->{$num})
                    {
                        $msgs->{$num} = {};
                    }
                    $msgs->{$num}{category} = 'coverage';
                    $msgs->{$num}{coverage} = 'e';
                    if ($cb)
                    {

                        $msgs->{$num}->{message} =
                            'Not all possibilities for this decision were '
                            . 'tested.  Remember that when you have N simple '
                            . 'conditions combined, you must test all N+1 '
                            . 'possibilities.';
                    }
                    else
                    {
                        if ($mi)
                        {
                            if ($ci)
                            {
                                $msgs->{$num}->{message} =
                                    'The decision(s) on this line were not '
                                    . 'tested.  Make sure you have separate '
                                    . 'tests for each way the decision can '
                                    . 'be true or false.';
                            }
                            else
                            {
                                $msgs->{$num}->{message} = 'This line was '
                                    . 'never executed by your tests.';
                            }
                        }
                        else
                        {
                            $msgs->{$num}->{message} = 'This line was '
                                . 'never executed by your tests.';
                        }
                    }

                    if ($includeCvg)
                    {
                        computeBranchesUncovered($num, $mb,
                                    $fileName, $msgs->{$num}->{message});
                    }
                }
                elsif ($mi)
                {
                    if (!defined $msgs->{$num})
                    {
                        $msgs->{$num} = {};
                    }
                    $msgs->{$num}{category} = 'coverage';
                    $msgs->{$num}{coverage} = 'e';
                    if ($ci)
                    {
                        $msgs->{$num}->{message} =
                            'Only part of this line was executed by your '
                            . 'tests.  Add tests to exercise all of the line.';
                    }
                    else
                    {
                        $msgs->{$num}->{message} =
                            'This line was never executed by your tests.';
                    }

                    if ($includeCvg)
                    {
                        computeStatementsUncovered($num, $fileName);
                    }
                }
            }
            if (defined $exemptLines{$fileName}->{method})
            {
                for my $methodRange (@{$exemptLines{$fileName}->{method}})
                {
                    if ($methodRange->[2] > 0)
                    {
                        $exemptMethodsCovered++;
                        $exemptComplexityCovered++;
                    }
                    else
                    {
                        $exemptMethodsMissed++;
                        $exemptComplexityMissed++;
                    }
                }
            }
            $methods -= $exemptMethodsCovered + $exemptMethodsMissed;
            $methodsCovered -= $exemptMethodsCovered;
            $lines -= $exemptLinesCovered + $exemptLinesMissed;
            $linesCovered -= $exemptLinesCovered;
            $instructions -=
                $exemptInstructionsCovered + $exemptInstructionsMissed;
            $instructionsCovered -= $exemptInstructionsCovered;
            $complexity -= $exemptComplexityCovered + $exemptComplexityMissed;
            $complexityCovered -= $exemptComplexityCovered;
            $branches -= $exemptBranchesCovered + $exemptBranchesMissed;
            $branchesCovered -= $exemptBranchesCovered;

            if ($pkgName ne '')
            {
                my $pkg = $pkgName;
                $pkg =~ s,/$,,o;
                $pkg =~ s,/,.,go;
                $cfg->setProperty("codeMarkup${codeMarkupNo}.pkgName",
                                  $pkg);
            }
            $cfg->setProperty("codeMarkup${codeMarkupNo}.className",
                              $className);
#            my $metrics = $file->{metrics};
#            $cfg->setProperty("codeMarkup${numCodeMarkups}.loc",
#                              $metrics->{loc}->content);
#            $cfg->setProperty("codeMarkup${numCodeMarkups}.ncloc",
#                              $metrics->{ncloc}->content);
            $counter = $file->{counter}('type', 'eq', 'LINE');
            my $myElementsCovered = 0 + $counter->{covered}->content;
            my $myElements = $myElementsCovered + $counter->{missed}->content;
            if ($myElements == 0)
            {
                $counter = $file->{counter}('type', 'eq', 'INSTRUCTION');
                $myElementsCovered = 0 + $counter->{covered}->content
                    - $exemptInstructionsCovered;
                $myElements = $myElementsCovered + $counter->{missed}->content
                    - $exemptInstructionsMissed;
            }
            else
            {
                $myElementsCovered -= $exemptLinesCovered;
                $myElements -= $exemptLinesCovered + $exemptLinesMissed;
            }
            $cfg->setProperty("codeMarkup${codeMarkupNo}.statements",
                              $myElements);
            $cfg->setProperty("codeMarkup${codeMarkupNo}.statementsCovered",
                              $myElementsCovered);

            $counter = $file->{counter}('type', 'eq', 'METHOD');
            if ($coverageMetric == 0
                || $coverageMetric == 2
                || $coverageMetric > 4)
            {
                $myElementsCovered = 0 + $counter->{covered}->content
                    - $exemptMethodsCovered;
                $myElements = $myElementsCovered + $counter->{missed}->content
                    - $exemptMethodsMissed;
            }
            elsif ($coverageMetric == 4)
            {
                my $complexityCounter =
                    $file->{counter}('type', 'eq', 'COMPLEXITY');
                $myElementsCovered += 0
                    + $complexityCounter->{covered}->content
                    - $exemptComplexityCovered;
                $myElements += 0 + $complexityCounter->{missed}->content
                    + $complexityCounter->{covered}->content
                    - $exemptComplexityMissed
                    - $exemptComplexityCovered;
            }
            $cfg->setProperty("codeMarkup${codeMarkupNo}.methods",
                              0 + $counter->{missed}->content
                              - $exemptMethodsMissed
                              + $counter->{covered}->content
                              - $exemptMethodsCovered);
            $cfg->setProperty("codeMarkup${codeMarkupNo}.methodsCovered",
                              0 + $counter->{covered}->content
                              - $exemptMethodsCovered);

            $counter = $file->{counter}('type', 'eq', 'BRANCH');
            if ($coverageMetric > 1 && $coverageMetric < 4)
            {
                $myElementsCovered += 0 + $counter->{covered}->content
                    - $exemptBranchesCovered;
                $myElements += 0 + $counter->{missed}->content
                    + $counter->{covered}->content
                    - $exemptBranchesMissed
                    - $exemptBranchesCovered;
            }
            $cfg->setProperty("codeMarkup${codeMarkupNo}.conditionals",
                              0 + $counter->{missed}->content
                              - $exemptBranchesMissed
                              + $counter->{covered}->content
                              - $exemptBranchesCovered);
            $cfg->setProperty(
                "codeMarkup${codeMarkupNo}.conditionalsCovered",
                0 + $counter->{covered}->content
                - $exemptBranchesCovered);

            if (!$includeCvg)
            {
                $myElements = 0;
                $myElementsCovered = 0;
            }
#            $gradedElements += $myElements;
#            $gradedElementsCovered += $myElementsCovered;

            $cfg->setProperty("codeMarkup${codeMarkupNo}.elements",
                              $myElements);
            $cfg->setProperty("codeMarkup${codeMarkupNo}.elementsCovered",
                              $myElementsCovered);
            $cfg->setProperty("codeMarkup${codeMarkupNo}.sourceFileName",
                              $fileName);
            $cfg->setProperty("codeMarkup${codeMarkupNo}.deductions",
#                ($myElements - $myElementsCovered) * $ptsPerUncovered +
                0 - $messageStats->{file}->{$fileName}->{pts}->content);
            $fileDeductionProperties{"codeMarkup${codeMarkupNo}.deductions"} =
                $myElements - $myElementsCovered;
            $cfg->setProperty("codeMarkup${codeMarkupNo}.remarks",
                (0 + $messageStats->{file}->{$fileName}->{remarks}->content));
        }
    }
        my $ptsPerUncovered = 0.0;
        my $label = '';

        if ($coverageMetric == 1
            || $coverageMetric == 3 || $coverageMetric == 4)
        {
            $gradedElements = $lines;
            $gradedElementsCovered = $linesCovered;
            $label = 'Lines';
            if ($gradedElements == 0)
            {
                $gradedElements =  $instructions;
                $gradedElementsCovered = $instructionsCovered;
                $label = 'Instructions';
            }
        }
        if ($coverageMetric == 2)
        {
            $gradedElements = $methods + $branches;
            $gradedElementsCovered = $methodsCovered + $branchesCovered;
            $label = 'Methods and Conditions';
        }
        elsif ($coverageMetric == 3)
        {
            $gradedElements += $branches;
            $gradedElementsCovered += $branchesCovered;
            $label .= ' and Conditions';
        }
        elsif ($coverageMetric == 4)
        {
            $gradedElements += $complexity;
            $gradedElementsCovered += $complexityCovered;
            $label = "Methods/$label/Conditions";
        }
        elsif ($coverageMetric != 1)
        {
            $gradedElements = $methods;
            $gradedElementsCovered = $methodsCovered;
            $label = 'Methods';
        }
        $cfg->setProperty("statElementsLabel", "$label Executed");

        if ($studentsMustSubmitTests)
        {
            $ptsPerUncovered = 0;
            if ($gradedElements > 0
                && $runtimeScoreWithoutCoverage > 0
                && ($gradedElementsCovered * 1.0 / $gradedElements)
                < $coverageGoal)
            {
                $ptsPerUncovered = -1.0 /
                    $gradedElements
                    * $runtimeScoreWithoutCoverage
                    * $coverageGoal;
            }
            if ($ptsPerUncovered < 0)
            {
                for my $prop (keys %fileDeductionProperties)
                {
                    my $deductions = 0 + $cfg->getProperty($prop, 0);
                    my $missedElements = $fileDeductionProperties{$prop};
                    $cfg->setProperty($prop,
                        $deductions + $ptsPerUncovered * $missedElements);
                }
            }
        }

        # Mark testingSectionStatus based on coverage information.
        if ($methods != $methodsCovered)
        {
            $testingSectionStatus{'methodsUncovered'} = 0;
        }

        if ($lines != $linesCovered)
        {
            $testingSectionStatus{'statementsUncovered'} = 0;
        }

        if ($branches != $branchesCovered)
        {
            $testingSectionStatus{'conditionsUncovered'} = 0;
        }

        processStatementsUncovered();
    }


}
$cfg->setProperty("numCodeMarkups", $numCodeMarkups);

my $time7 = time;
if ($debug)
{
    print "\n", ($time7 - $time6), " seconds\n";
}


#=============================================================================
# generate HTML version of student testing results
#=============================================================================
if ($status{'studentHasSrcs'}
    && ($studentsMustSubmitTests
        || (defined $status{'studentTestResults'}
            && $status{'studentTestResults'}->hasResults)))
{
    my $sectionTitle = "Results from Running Your Tests ";
    if ($codingSectionStatus{'compilerErrors'} == 1)
    {
        # Only generate this section if compilation was successful
    if (!defined $status{'studentTestResults'})
    {
        $sectionTitle .= "<b class=\"warn\">(No Test Results!)</b>";

        # Mark results in testingSectionStatus as well so that we can fill
        # the radial bar.
        $testingSectionStatus{'resultsPercent'} = 0;
    }
    elsif ($status{'studentTestResults'}->testsExecuted == 0)
    {
        $sectionTitle .= "<b class=\"warn\">(No Tests Submitted!)</b>";
        $testingSectionStatus{'resultsPercent'} = 0;
    }
    elsif ($status{'studentTestResults'}->allTestsPass)
    {
        $sectionTitle .= "(100%)";
        $testingSectionStatus{'resultsPercent'} = 100;
    }
    else
    {
        $sectionTitle .= "<b class=\"warn\">($studentCasesPercent%)</b>";
        $testingSectionStatus{'resultsPercent'} = $studentCasesPercent;
    }

    $status{'feedback'}->startFeedbackSection(
        $sectionTitle,
        ++$expSectionId,
        $status{'studentTestResults'}->allTestsPass);

    if ($allStudentTestsMustPass
        && $status{'studentTestResults'}->testsFailed > 0)
    {
        $status{'feedback'}->print(
            "<p><b class=\"warn\">All of your tests "
            . "must pass for you to get further feedback.</b>\n");
    }

    # Transform the plain text JUnit results to an interactive HTML view.
    JavaTddPlugin::transformTestResults("student_",
        "$resultDir/student-results.txt",
        "$resultDir/student-results.html"
        );

    # Mark the Errors and Failures flags for the testingSectionStatus.
    $testingSectionStatus{'errors'} = negateValueZeroToOneAndOneToZero(
        checkForPatternInFile("$resultDir/student-results.txt",
        'Caused an ERROR'));
    $testingSectionStatus{'failures'} = negateValueZeroToOneAndOneToZero(
        checkForPatternInFile("$resultDir/student-results.txt", 'FAILED'));

    # Access each suite and generate error struct for
    # Testing errors and failures
    computeTestingErrorFailureStructs();

    open(STUDENTRESULTS, "$resultDir/student-results.html");
    my @lines = <STUDENTRESULTS>;
    close(STUDENTRESULTS);
    if ($#lines >= 0)
    {
        $status{'feedback'}->print(<<EOF);
<p>The results of running your own test cases are shown below. Click on a
failed test to see the reason for the failure and an execution trace that
shows where the error occurred.</p>
EOF
        $status{'feedback'}->print(@lines);
    }
    unlink "$resultDir/student-results.html";

    @lines = linesFromFile("$resultDir/student-out.txt", 75000, 4000);
    if ($#lines >= 0)
    {
        $status{'feedback'}->startFeedbackSection(
            "Output from Your Tests", ++$expSectionId, 1, 2,
            "<pre>", "</pre>");
        $status{'feedback'}->print(@lines);
        $status{'feedback'}->endFeedbackSection;
    }

    $status{'feedback'}->endFeedbackSection;
    }

    if ($gradedElements > 0
        || (defined $status{'studentTestResults'}
            && $status{'studentTestResults'}->testsExecuted > 0))
    {
        $codeCoveragePercent = 0;
        if ($gradedElements > 0)
        {
            $codeCoveragePercent =
                int(($gradedElementsCovered * 1.0 / $gradedElements)
                / $coverageGoal * 100.0 + 0.5);
            if ($codeCoveragePercent > 100) { $codeCoveragePercent = 100; }
            if (($gradedElementsCovered * 1.0 / $gradedElements) < $coverageGoal
                && $codeCoveragePercent == 100)
            {
                # Don't show 100% if some cases failed
                $codeCoveragePercent--;
            }
        }

        # Code Coverage Percent of testingSectionStatus
        $testingSectionStatus{'codeCoveragePercent'} = $codeCoveragePercent;

        if (!$useEnhancedFeedback)
        {
        $sectionTitle = "Code Coverage from Your Tests ";
        if ($gradedElements == 0)
        {
            $sectionTitle .= "<b class=\"warn\">(No Coverage!)</b>";
        }
        elsif (($gradedElementsCovered * 1.0 / $gradedElements)
            >= $coverageGoal)
        {
            $sectionTitle .= "(100%)";
        }
        else
        {
            $sectionTitle .= "<b class=\"warn\">($codeCoveragePercent%)</b>";
        }

        $status{'feedback'}->startFeedbackSection(
            $sectionTitle, ++$expSectionId, 1);

        $status{'feedback'}->print("<p><b>Code Coverage: ");
        if ($codeCoveragePercent < 100)
        {
            $status{'feedback'}->print(
                "<b class=\"warn\">$codeCoveragePercent%</b>");
        }
        else
        {
            $status{'feedback'}->print("$codeCoveragePercent%");
        }

        my $descr = $cfg->getProperty("statElementsLabel", "Methods Executed");
        $descr =~ tr/A-Z/a-z/;
        $descr =~ s/\s*executed\s*$//;
        $status{'feedback'}->print(<<EOF);
</b> (percentage of $descr exercised by your tests)</p>
<p>You can improve your testing by looking for any
<span style="background-color:#F0C8C8">lines highlighted in this color</span>
in your code listings above.  Such lines have not been sufficiently
tested--hover your mouse over them to find out why.
</p>
EOF
        $status{'feedback'}->endFeedbackSection;
        }
    }
}

if (defined $status{'studentTestResults'}
    && $status{'studentTestResults'}->hasResults)
{
    $status{'studentTestResults'}->saveToCfg($cfg, 'student.test');
}
if (defined $status{'instrTestResults'}
    && $status{'instrTestResults'}->hasResults)
{
    $status{'instrTestResults'}->saveToCfg($cfg, 'instructor.test');
}
if (defined $messageStats)
{
    my $staticResults = '';
    # For some reason, iteration in $messageStats is broken here, so
    # simply convert to text and back to get it back into shape.
    print "about to reframe message stats\n" if ($debug);
    print $messageStats->data(tree=>$messageStats) if ($debug);
    if (!$messageStats->{file}->null)
    {
        $messageStats = XML::Smart->new(
            $messageStats->data(tree => $messageStats))->{root};
    }
    print "reframed message stats\n" if ($debug);
    foreach my $grp ($messageStats->('@keys'))
    {
        if (   $grp eq 'file'
            || $grp eq 'num'
            || $grp eq 'pts'
            || $grp eq 'collapse')
        {
            next;
        }

        foreach my $rule ($messageStats->{$grp}('@keys'))
        {
            if (   $rule eq 'file'
                || $rule eq 'num'
                || $rule eq 'pts'
                || $rule eq 'collapse')
            {
                next;
            }
            my $thisRule = '{'
                . '"name"="' . $rule . '";'
                . '"group"="' . $grp . '";'
                . '"count"="' . $messageStats->{$grp}->{$rule}->{num} . '";'
                . '"pts"="' . $messageStats->{$grp}->{$rule}->{pts} . '";'
                . '}';
            if ($staticResults eq '')
            {
                $staticResults = $thisRule;
            }
            else
            {
               $staticResults .= ',' . $thisRule;
            }
        }
    }
    $cfg->setProperty('static.analysis.results', '(' . $staticResults . ')');
}
$cfg->setProperty('outcomeProperties',
    '("instructor.test.results", "student.test.results", '
    . '"static.analysis.results")');


sub markBehaviorSectionUsingInstrTests
{
    for my $suite ($status{'instrTestResults'}->listOfHashes)
    {
        if ($suite->{'level'} == 4 && $suite->{'code'} == 31)
        {
            $behaviorSectionStatus{'outOfMemoryErrors'} = 0;
        }
        elsif ($suite->{'level'} == 4 && $suite->{'code'} == 32)
        {
            $behaviorSectionStatus{'stackOverflowErrors'} = 0;
# https://junit.org/junit4/javadoc/4.12/org/junit/runners/model/TestTimedOutException.html
# Note that https://docs.oracle.com/javase/7/docs/api/java/util/concurrent/TimeoutException.html,
# that's different from a test being timedout. TimeoutException is caught under errors
        }
        elsif ($suite->{'level'} == 5 && index(lc($suite->{'trace'}),
            lc("TestTimedOutException")) != -1)
        {
            $behaviorSectionStatus{'testsTakeTooLong'} = 0;
        }
    }
}

sub markCodingSectionUsingInstrResults
{
    for my $suite ($status{'instrTestResults'}->listOfHashes)
    {
        if ($suite->{'level'} == 4 && $suite->{'code'} == 29)
        {
            $codingSectionStatus{'signatureErrors'} = 0;
            return;
        }
    }
}

#=============================================================================
# generate reference test results
#=============================================================================
if (defined $status{'instrTestResults'})
{
    my $sectionTitle = "Estimate of Problem Coverage ";
    if ($status{'instrTestResults'}->testsExecuted == 0
        || ($studentsMustSubmitTests
            && !$status{'studentTestResults'}->hasResults))
    {
        $sectionTitle .=
            "<b class=\"warn\">(Unknown!)</b>";
        $instructorCasesPercent = "unknown";
    }
    elsif ($status{'instrTestResults'}->allTestsPass)
    {
        $sectionTitle .= "(100%)";
        $instructorCasesPercent = 100;
    }
    else
    {
        $instructorCasesPercent =
            int($status{'instrTestResults'}->testPassRate * 100.0 + 0.5);
        if ($instructorCasesPercent == 100)
        {
            # Don't show 100% if some cases failed
            $instructorCasesPercent--;
        }
        $sectionTitle .= "<b class=\"warn\">($instructorCasesPercent%)</b>";
    }

    if ($useEnhancedFeedback)
    {
        $sectionTitle = "Estimate of Problem Coverage";
    }

    $status{'feedback'}->startFeedbackSection(
        $sectionTitle, ++$expSectionId,
        $useEnhancedFeedback || ($instructorCasesPercent >= 100));
    $status{'feedback'}->print("<p><b>Problem coverage: ");
    if ($instructorCasesPercent == 100)
    {
        $status{'feedback'}->print("100%");
    }
    else
    {
        $status{'feedback'}->print(
            "<b class=\"warn\">$instructorCasesPercent");
        if ($instructorCasesPercent ne "unknown")
        {
            $status{'feedback'}->print("%");
        }
        $status{'feedback'}->print("</b>");
    }
    $status{'feedback'}->print("</b></p>");


    if ($status{'compileErrs'}) # $instructorCases == 0
    {
        $status{'feedback'}->print(<<EOF);
<p><b class="warn">Your code failed to compile correctly against
the reference tests.</b></p>
<p>This is most likely because you have not named your class(es)
as required in the assignment, have failed to provide one or more required
methods, or have failed to use the required signature for a method.</p>
<p>Failure to follow these constraints will prevent the proper assessment
of your solution and your tests.</p>
EOF
        if ($status{'compileMsgs'} ne "")
        {
            $status{'feedback'}->print(<<EOF);
<p>The following specific error(s) were discovered while compiling
reference tests against your submission:</p>
</p>
<pre>
EOF
            $status{'feedback'}->print($status{'compileMsgs'});
            $status{'feedback'}->print("</pre>\n");
        }
    }
    elsif ($studentsMustSubmitTests
        && !$status{'studentTestResults'}->hasResults)
    {
        $status{'feedback'}->print(<<EOF);
<p><b class="warn">You are required to write your own software tests
for this assignment.  You must provide your own tests
to get further feedback.</b></p>
EOF
    }
    elsif ($status{'instrTestResults'}->allTestsFail)
    {
        my $hints = $status{'instrTestResults'}->formatHints(
            1, $hintsLimit);
    print "hints = $hints\n";
        if (defined $hints && $hints ne "" && $hints =~ /honor code viol/i)
        {
            $hints =~ s/<p>Failure during test case setup[^<]*<\/p>//g;
            $hints =~ s/symptom: [^\s]*:\s*//g;
            $hints =~ s/\s*expected: \S*false\S* but was: \S*true\S*//g;
            $hints =~ s/<pre>/<p>/g;
            $hints =~ s/<\/pre>/<\/p>/g;
        $status{'feedback'}->print(<<EOF);
<p><b class="warn">$hints</b></p>
EOF
    }
        else
        {
        $status{'feedback'}->print(<<EOF);
<p><b class="warn">Your problem setup does not appear to be
consistent with the assignment.</b></p>
EOF
        if ($studentsMustSubmitTests)
        {
            $status{'feedback'}->print(<<EOF);
<p>For this assignment, the proportion of the problem that is covered by your
test cases is being assessed by running a suite of reference tests against
your solution, and comparing the results of the reference tests against the
results produced by your tests.</p>
EOF
        }
        else
        {
            $status{'feedback'}->print(<<EOF);
<p>For this assignment, the proportion of the problem that is covered by your
solution is being assessed by running a suite of reference tests against
your solution.</p>
EOF
        }
        $status{'feedback'}->print(<<EOF);
<p>In this case, <b>none of the reference tests pass</b> on your solution,
which may mean that your solution (and your tests) make incorrect assumptions
about some aspect of the required behavior.
This discrepancy prevented Web-CAT from properly assessing the thoroughness
of your solution or your test cases.</p>
<p>Double check that you have carefully followed all initial conditions
requested in the assignment in setting up your solution.</p>
EOF
        }
    }
    elsif ($status{'instrTestResults'}->allTestsPass)
    {
        $status{'feedback'}->print(<<EOF);
<p>Your solution appears to cover all required behavior for this assignment.
EOF
        if ($studentsMustSubmitTests)
        {
            $status{'feedback'}->print(<<EOF);
Make sure that your tests cover all of the behavior required.</p>
<p>For this assignment, the proportion of the problem that is covered by your
test cases is being assessed by running a suite of reference tests against
your solution, and comparing the results of the reference tests against the
results produced by your tests.</p>
EOF
        }
        else
        {
            $status{'feedback'}->print(<<EOF);
</p><p>For this assignment, the proportion of the problem that is covered by
your solution is being assessed by running a suite of reference tests against
your solution.</p>
EOF
        }
    }
    else
    {
        if ($studentsMustSubmitTests)
        {
            $status{'feedback'}->print(<<EOF);
<p>For this assignment, the proportion of the problem that is covered by your
test cases is being assessed by running a suite of reference tests against
your solution, and comparing the results of the reference tests against the
results produced by your tests.</p>
<p>Differences in test results indicate that your code still contains bugs.
Your code appears to cover
<b class="warn">only $instructorCasesPercent%</b>
of the behavior required for this assignment.</p>
<p>
Your test cases are not detecting these defects, so your testing is
incomplete--covering at most <b class="warn">only
$instructorCasesPercent%</b>
of the required behavior, possibly even less.</p>
EOF
        }
        else
        {
            $status{'feedback'}->print(<<EOF);
<p>For this assignment, the proportion of the problem that is covered by your
solution is being assessed by running a suite of reference tests against
your solution.</p>
<p>
Test results indicate that your code still contains bugs.
Your code appears to cover
<b class="warn">only $instructorCasesPercent%</b>
of the behavior required for this assignment.</p>
EOF
        }
        $status{'feedback'}->print(<<EOF);
<p>Double check that you have carefully followed all initial conditions
requested in the assignment in setting up your solution, and that you
have also met all requirements for a complete solution in the final
state of your program.</p>
EOF
    }
    if ($hintsLimit != 0 && !$status{'compileErrs'})
    {
        if ($studentsMustSubmitTests
            && $hasJUnitErrors
            && $junitErrorsHideHints)
        {
            $status{'feedback'}->print(<<EOF);
<p>Your JUnit test classes contain <b class="warn">problems that must be
fixed</b> before you can receive any more specific feedback.  Be sure that
all of your test classes contain test methods, and that all of your test
methods include appropriate assertions to check for expected behavior.
You must fix these problems with your own tests to get further feedback.</p>
EOF
        }
        elsif ($studentsMustSubmitTests
            && (!$status{'studentTestResults'}->hasResults
                || $gradedElements == 0
                || $gradedElementsCovered / $gradedElements * 100.0 <
                   $minCoverageLevel))
        {
            $status{'feedback'}->print(<<EOF);
<p>Your JUnit test cases <b class="warn">do not exercise enough of your
solution</b> for you to receive any more specific feedback.  Improve your
testing by writing more test cases that exercise more of your solution's
features.  Be sure to write <b>meaningful tests</b> that include appropriate
assertions to check for expected behavior.  You must improve your testing
to get further feedback.</p>
EOF
        }
        else
        {
            my $hints = $status{'instrTestResults'}->formatHints(
                0, $hintsLimit);
            if (defined $hints && $hints ne "")
            {
                my $extra = "";
                if ($studentsMustSubmitTests)
                {
                    $extra = "and your testing ";
                }
                $status{'feedback'}->print(<<EOF);
<p>The following hint(s) may help you locate some ways in which your solution
$extra may be improved:</p>
$hints
EOF
            }
        }
    }
    elsif ($extraHintMsg ne "")
    {
        $status{'feedback'}->print("<p>$extraHintMsg</p>");
    }

    # Generate staff-targeted info
    {
        if ($codingSectionStatus{'compilerErrors'} == 1)
        {
        $status{'instrFeedback'}->startFeedbackSection(
            "Detailed Reference Test Results", ++$expSectionId, 1);
        my $hints = $status{'instrTestResults'}->formatHints(2);
        if (defined $hints && $hints ne "")
        {
            $status{'instrFeedback'}->print($hints);
            $status{'instrFeedback'}->print("\n");
        }

        # Transform the plain text JUnit results into an interactive HTML
        # view.
        JavaTddPlugin::transformTestResults('instr_',
            "$resultDir/instr-results.txt",
            "$resultDir/instr-results.html"
            );
        }

        # Mark Behavior Section Status appropriately
        $behaviorSectionStatus{'errors'} = negateValueZeroToOneAndOneToZero(
            checkForPatternInFile(
            "$resultDir/instr-results.txt", 'Caused an ERROR'));

        $behaviorSectionStatus{'failures'} = negateValueZeroToOneAndOneToZero(
            checkForPatternInFile(
            "$resultDir/instr-results.txt", 'FAILED'));

        markBehaviorSectionUsingInstrTests();
        markCodingSectionUsingInstrResults();

        # Access each suite and generate error struct for Coding (Signature
        # Errors) and Behavior sections
        computeBehaviorSectionSignatureStructs();

        $behaviorSectionStatus{'problemCoveragePercent'} =
            $instructorCasesPercent;

        if ($codingSectionStatus{'compilerErrors'} == 1)
        {
        open(INSTRRESULTS, "$resultDir/instr-results.html");
        my @lines = <INSTRRESULTS>;
        close(INSTRRESULTS);
        if ($#lines >= 0)
        {
            $status{'instrFeedback'}->print(<<EOF);
<p>The results of running the instructor's reference test cases are shown
below. Click on a failed test to see the reason for the failure and an
execution trace that shows where the error occurred.</p>
EOF
            $status{'instrFeedback'}->print(@lines);
        }
        unlink "$resultDir/instr-results.html";

        @lines = linesFromFile("$resultDir/instr-out.txt", 75000, 4000);
        if ($#lines >= 0)
        {
            $status{'instrFeedback'}->startFeedbackSection(
                "Output from Reference Tests", ++$expSectionId, 1, 2,
                "<pre>", "</pre>");
            $status{'instrFeedback'}->print(@lines);
            $status{'instrFeedback'}->endFeedbackSection;
        }
        $status{'instrFeedback'}->endFeedbackSection;
        }
    }
}


#=============================================================================
# generate HTML versions of any other source files
#=============================================================================

if ($debug > 3)
{
foreach my $ff (keys %codeMessages)
{
    print "file $ff:\n";
    foreach my $line (keys %{$codeMessages{$ff}})
    {
        print "file $ff: line $line:\n";
        if (defined $codeMessages{$ff}->{$line}{violations})
        {
            my @comments =
                sort { $b->{line}->content  <=>  $a->{line}->content }
                @{ $codeMessages{$ff}->{$line}{violations} };
            print "file $ff: line $line: total comments = ",
                $#comments + 1, "\n";
            foreach my $c (@comments)
            {
                 my $message = $c->{message}->content;
                 if (!defined $message || $message eq '')
                 {
                     $message = $c->content;
                 }
                 # print "comment = ", $c->data(tree => $c), "\n";
                 print 'group = ', $c->{group}->content, ', line = ',
                     $c->{line}->content, ', message = ',
                     $message, "\n";
            }
        }
    }
}
}


# The extended error messages from config files which replace the builtin
# messages from Checkstyle and PMD are longer.
# Use those messages as 'enhancedMessage' and shorter messages as
# 'errorMessage'.
sub addShorterMessages
{
    my $struct = shift;
    my $rule = shift;

    my $shortMessage = codingStyleMessageValue($rule);

    if ($shortMessage)
    {
        $struct = expandedMessage->new(
            entityName => $struct->entityName,
            lineNum => $struct->lineNum,
            errorMessage => $shortMessage,
            linesOfCode => $struct->linesOfCode,
            enhancedMessage => $struct->errorMessage,
            );
    }

    return $struct;
}


sub processCodingStyleStruct
{
    my $group = shift;
    my $rule = shift;
    my $struct = shift;

    my $key = 'other';

    if (lc($group) eq 'coding')
    {
        $key = 'codingFlaws';
    }
    elsif (index(lc($group), 'testing') != -1)
    {
        $key = 'junitTests';
    }
    elsif (index(lc($rule), 'javadoc') != -1)
    {
        $key = 'javadoc';
    }
    elsif (index(lc($rule), 'indentation') != -1)
    {
        $key = 'indentation';
    }
    elsif (index(lc($rule), 'whitespace') != -1)
    {
        $key = 'whitespace';
    }
    elsif (index(lc($rule), 'linelength') != -1)
    {
        $key = 'lineLength';
    }

    $struct = addShorterMessages($struct, $rule);

    if (defined $perFileRuleStruct{$key}{'data'}{$rule})
    {
        push @{$perFileRuleStruct{$key}{'data'}{$rule}}, $struct;
        $perFileRuleStruct{$key}{'count'}{$rule}++;
    }
    else
    {
        my @temp;
        push @temp, $struct;
        $perFileRuleStruct{$key}{'data'}{$rule} = [@temp];
        $perFileRuleStruct{$key}{'count'}{$rule} = 1;
    }
}

# Only Hints are used as error message; others aew undef
sub generateHintErrorStruct
{
    my $errorMessage = shift;

    my $errorStruct = expandedMessage->new(
        entityName => '',
        lineNum => '',
        errorMessage => $errorMessage,
        linesOfCode => '',
        enhancedMessage => '',
        );

    return $errorStruct;
}

# Entire error struct is generated; all fields
sub generateCompleteErrorStruct
{
    my $fileName = shift;
    my $lineNum = shift;
    my $errorMessage = shift;
    my $enhancedMessage = shift || '';

    my $codeLines = extractAboveBelowLinesOfCode($fileName, $lineNum);

    my $errorStruct = expandedMessage->new(
        entityName => $fileName,
        lineNum => $lineNum,
        errorMessage => $errorMessage,
        linesOfCode => $codeLines,
        enhancedMessage => $enhancedMessage,
        );

    return $errorStruct;
}


# Use this to generate expanded content for Style Section and
# {codingFlaws, junitTests} in Coding
#Value would be an array of structs as we will store all the messages and
# then sort based on count of each group

foreach my $ff (keys %codeMessages)
{
    foreach my $line (keys %{$codeMessages{$ff}})
    {
        if (defined $codeMessages{$ff}->{$line}{violations})
        {
            my @comments =
                sort { $b->{line}->content  <=>  $a->{line}->content }
                @{ $codeMessages{$ff}->{$line}{violations} };

            foreach my $c (@comments)
            {
                 my $message = $c->{message}->content;
                 if (!defined $message || $message eq '')
                 {
                     $message = $c->content;
                 }

                 #print 'group = ', $c->{group}->content, ', line = ',
                     #$c->{line}->content, ', message = ',
                     #$message, "\n";
                     #print $c->{rule}->content;
                     #print("\n");

                 my $lineNum = $c->{line}->content;

                 # This is the case of "TestsHaveAssertions" rule from pmd
                 # where beginline is the one which contains the declaration
                 # of the method and we would want to use that in highlighting
                 # the code in feedback.
                 if (index(lc($c->{group}->content), 'testing') != -1
                     && $c->{beginline}->content)
                 {
                     $lineNum = $c->{beginline}->content;
                 }

                 my $codingStyleStruct = generateCompleteErrorStruct(
                     $ff, $lineNum, $message);

                 processCodingStyleStruct(
                     $c->{group}->content,
                     $c->{rule}->content,
                     $codingStyleStruct);
            }
        }
    }
}

# build struct array based on counts(descending-add in that order) in the hash
# by picking hash values which are scalars (single structs)
# Used for compiler errors and warnings, coverage(methods,statements,branches)
# As they have only struct per key in the hash
sub addStructsToExpandedSectionsFromScalarHashValues
{
    my $hashOuterKey = shift;
    my @errorStructs;

    if (!defined $perFileRuleStruct{$hashOuterKey})
    {
        return @errorStructs;
    }

    my %structHash = %{$perFileRuleStruct{$hashOuterKey}{'data'}};
    my %countHash = %{$perFileRuleStruct{$hashOuterKey}{'count'}};


    foreach my $key (sort { $countHash{$b} <=> $countHash{$a} } keys %countHash)
    {
        push @errorStructs, $structHash{$key};
    }

    return @errorStructs;
}

# Here the value in the hash is an array of error structs
# pick one error from each subcategory (sorted based on frequency) and repeat
# this process
sub addStructsToExpandedSectionsFromArrayHashValues
{
    my $key = shift;

    my @expandedMessageStruct;

    if (!defined $perFileRuleStruct{$key})
    {
        return @expandedMessageStruct;
    }

    my $keyCount = keys %{$perFileRuleStruct{$key}{'count'}};

    if ($key eq 'codingFlaws'
        || $key eq 'junitTests'
        || $key eq 'errors'
        || $key eq 'behaviorErrors'
        || $key eq 'javadoc'
        || $key eq 'whitespace'
        || $key eq 'other')
    {
        # These have subcategories
        # Limit the number of errors per subcategory to $maxErrorsPerSubcategory
        # Remaining categories are limited after they are grouped by file.

        foreach my $rule (sort { $perFileRuleStruct{$key}{'count'}{$b} <=> $perFileRuleStruct{$key}{'count'}{$a} }
            keys %{$perFileRuleStruct{$key}{'count'}})
        {
            my $errorsPerRule = int($maxErrorsPerSubcategory/$keyCount);
            my $arraySize = @{$perFileRuleStruct{$key}{'data'}{$rule}};

            while ($errorsPerRule > 0 && $arraySize > 0)
            {
                my $struct = shift @{$perFileRuleStruct{$key}{'data'}{$rule}};
                push @expandedMessageStruct, $struct;

                $errorsPerRule--;
                $arraySize--;
            }

            if ($arraySize == 0)
            {
                delete $perFileRuleStruct{$key}{'data'}{$rule};
                delete $perFileRuleStruct{$key}{'count'}{$rule};
            }
            else
            {
                push @expandedMessageStruct, countErrorsPerFileOverLimit(
                    \@{$perFileRuleStruct{$key}{'data'}{$rule}});
            }
        }
    }
    else
    {
        # keyCount is "1" in this case as there is no subcategory
        # Other keys
        # These errors are grouped by file
        # They are limited after the groupStructsByFileName is called on them
        while ($keyCount > 0)
        {
            foreach my $rule (sort { $perFileRuleStruct{$key}{'count'}{$b} <=> $perFileRuleStruct{$key}{'count'}{$a} }
                keys %{$perFileRuleStruct{$key}{'count'}})
            {
                my $struct = shift @{$perFileRuleStruct{$key}{'data'}{$rule}};

                push @expandedMessageStruct, $struct;

                my $arraySize = @{$perFileRuleStruct{$key}{'data'}{$rule}};
                if ($arraySize == 0)
                {
                    delete $perFileRuleStruct{$key}{'data'}{$rule};
                    delete $perFileRuleStruct{$key}{'count'}{$rule};
                }
            }
            $keyCount = keys %{$perFileRuleStruct{$key}{'count'}};
        }
    }

    return @expandedMessageStruct;
}

# Add Struct to perFileRuleStruct based on inner and outer key
sub addErrorFailureStructToHash
{
    my $outerKey = shift;
    my $innerKey = shift;
    my $struct = shift;

    if (defined $perFileRuleStruct{$outerKey}{'data'}{$innerKey})
    {
        push @{$perFileRuleStruct{$outerKey}{'data'}{$innerKey}}, $struct;
        $perFileRuleStruct{$outerKey}{'count'}{$innerKey}++;
    }
    else
    {
        my @temp;
        push @temp, $struct;
        $perFileRuleStruct{$outerKey}{'data'}{$innerKey} = [@temp];
        $perFileRuleStruct{$outerKey}{'count'}{$innerKey} = 1;
    }
}


# Adds $linesAboveAssertionFailure lines above the test failure line.
sub addLinesAboveAssertionFailure
{
    my $assertionStruct = shift;
    my $methodName = shift;
    my $failureLine = $assertionStruct->lineNum;
    my $startLineNum = $assertionStruct->lineNum - $linesAboveAssertionFailure;

    my $codeLines = '';

    # To ensure that we don't go out of the method's beginning.
    if ($methodBeginLineNum{$methodName} > $startLineNum)
    {
        $startLineNum  = $methodBeginLineNum{$methodName};
    }

    # One line above the failure line is already contained in the linesOfCode.
    while ($startLineNum < $failureLine - 1)
    {
        $codeLines .= extractLineOfCode(
            $assertionStruct->entityName, $startLineNum);
        $startLineNum++;
    }

    $assertionStruct = expandedMessage->new(
        entityName => $assertionStruct->entityName,
        lineNum => $assertionStruct->lineNum,
        errorMessage => $assertionStruct->errorMessage,
        linesOfCode => $codeLines . $assertionStruct->linesOfCode,
        enhancedMessage => $assertionStruct->enhancedMessage,
        );

    return $assertionStruct;
}


# Suites from student.inc
sub computeTestingErrorFailureStructs
{
    my @studentSuites = $status{'studentTestResults'}->listOfHashes;

    for my $suite (@studentSuites)
    {
        # Implies this test passed
        if ($suite->{'level'} == 1)
        {
            next;
        }

        # Assertion Failures
        if ($suite->{'level'} == 2)
        {
            my $fileName;
            my $lineNum;
            my $assertionStruct;

           ($fileName, $lineNum) =
               extractFileNameFromStackTrace($suite->{'trace'}, 1);

            if (!defined $fileName || !defined $lineNum)
            {
                $assertionStruct = generateHintErrorStruct(
                    $suite->{'test'} . ': ' . $suite->{'message'});
            }
            else
            {
                $assertionStruct = generateCompleteErrorStruct($fileName,
                    $lineNum, $suite->{'test'} . ': ' . $suite->{'message'});
                $assertionStruct = addLinesAboveAssertionFailure(
                    $assertionStruct, $suite->{'test'});
            }

            addErrorFailureStructToHash(
                'failures', 'failures', $assertionStruct);
            next;
        }

        # This is the case for errors
        my $fileName;
        my $lineNum;
        my $errorStruct;
        my $message = $suite->{'message'};

        if (defined $suite->{'exception'})
        {
            my $exName = $suite->{'exception'};
            $exName =~ s/^.*\.//o;
            $message = $exName . ': ' . $message;
        }

        if ($suite->{'level'} == 4 && $suite->{'code'} == 32)
        {
            $errorStruct =
                generateStackOverflowErrorStruct($suite->{'trace'});

            if (!defined $errorStruct)
            {
                $errorStruct = generateHintErrorStruct($message);
            }
        }
        else
        {
            ($fileName, $lineNum) =
                extractFileNameFromStackTrace($suite->{'trace'}, 1);

            if (!defined $fileName || !defined $lineNum)
            {
                $errorStruct = generateHintErrorStruct($message);
            }
            else
            {
                $errorStruct = generateCompleteErrorStruct(
                    $fileName, $lineNum, $message);
            }
        }

        if (!defined $suite->{'exception'})
        {
            addErrorFailureStructToHash('errors', $message, $errorStruct);
        }
        else
        {
            addErrorFailureStructToHash(
                'errors', $suite->{'exception'}, $errorStruct);
        }
    }
}

#We use this to ensure that duplicate messages (which imply the same) aren't displayed in
#the feedback. This is used for Signature Errors and Behavior Failures.
my %signatureErrorFailureMessages;

# Suites from instr.inc
sub computeBehaviorSectionSignatureStructs
{
    my @instrSuites = $status{'instrTestResults'}->listOfHashes;

    for my $suite (@instrSuites)
    {
        # Implies this test passed
        if ($suite->{'level'} == 1)
        {
            next;
        }

        # Assertion Failures
        if ($suite->{'level'} == 2)
        {
            if (defined $signatureErrorFailureMessages{$suite->{'message'}})
            {
                next;
            }
            else
            {
                $signatureErrorFailureMessages{$suite->{'message'}} = 1;
            }

            my $assertionStruct = generateHintErrorStruct($suite->{'message'});

            # note that the key is 'behaviorFailures', so that there is no
            # conflict with 'failures' which is key for testing
            addErrorFailureStructToHash(
                'behaviorFailures', 'behaviorFailures', $assertionStruct);
            next;
        }

        # Signature Errors
        if ($suite->{'level'} == 4 && $suite->{'code'} == 29)
        {
            if (defined $signatureErrorFailureMessages{$suite->{'message'}})
            {
                next;
            }
            else
            {
                $signatureErrorFailureMessages{$suite->{'message'}} = 1;
            }

            my $fileName;
            my $lineNum;
            my $signatureErrorStruct;

            ($fileName, $lineNum) =
                extractFileNameFromStackTrace($suite->{'trace'}, 0);

            if (!defined $fileName || !defined $lineNum)
            {
                $signatureErrorStruct =
                    generateHintErrorStruct($suite->{'message'});
            }
            else
            {
                $signatureErrorStruct = generateCompleteErrorStruct(
                    $fileName, $lineNum, $suite->{'message'});
            }

            addErrorFailureStructToHash('signatureErrors', 'signatureErrors',
                $signatureErrorStruct);
            next;
        }

        # StackOverflowError
        if ($suite->{'level'} == 4 && $suite->{'code'} == 32)
        {
            my $stackOverflowErrorStruct;
            $stackOverflowErrorStruct =
                generateStackOverflowErrorStruct($suite->{'trace'});

            if (!defined $stackOverflowErrorStruct)
            {
                $stackOverflowErrorStruct =
                    generateHintErrorStruct($suite->{'message'});
            }

            addErrorFailureStructToHash(
                'stackOverflowErrors',
                'stackOverflowErrors',
                $stackOverflowErrorStruct);
            next;
        }

        # OutOfMemoryError
        if ($suite->{'level'} == 4 && $suite->{'code'} == 31)
        {
            my $fileName;
            my $lineNum;
            my $outOfMemoryStruct;

            ($fileName, $lineNum) =
                extractFileNameFromStackTrace($suite->{'trace'}, 1);

            if (!defined $fileName || !defined $lineNum)
            {
                $outOfMemoryStruct =
                    generateHintErrorStruct($suite->{'message'});
            }
            else
            {
                $outOfMemoryStruct = generateCompleteErrorStruct(
                    $fileName, $lineNum, $suite->{'message'});
            }

            addErrorFailureStructToHash(
                'outOfMemoryErrors', 'outOfMemoryErrors', $outOfMemoryStruct);
            next;
        }

        # Test Timedout
        if ($suite->{'level'} == 5
            && index(lc($suite->{'trace'}), lc('TestTimedOutException'))
            != -1)
        {
            my $testsTakeLongStruct =
                generateHintErrorStruct($suite->{'message'});

            addErrorFailureStructToHash(
                'testsTakeTooLong', 'testsTakeTooLong', $testsTakeLongStruct);
            next;
        }

        my $fileName;
        my $lineNum;
        my $errorStruct;
        my $message = $suite->{'message'};

        if (defined $suite->{'exception'})
        {
            my $exName = $suite->{'exception'};
            $exName =~ s/^.*\.//o;
            $message = $exName . ': ' . $message;
        }

        ($fileName, $lineNum) =
            extractFileNameFromStackTrace($suite->{'trace'}, 1);

        if (!defined $fileName || !defined $lineNum)
        {
            $errorStruct = generateHintErrorStruct($message);
        }
        else
        {
            $errorStruct = generateCompleteErrorStruct(
                $fileName, $lineNum, $message);
        }

        # note that the key is 'behaviorErrors', so that there is no conflict
        # with 'errors' which is key for testing
        if (!defined $suite->{'exception'})
        {
            addErrorFailureStructToHash(
                'behaviorErrors', $message, $errorStruct);
        }
        else
        {
            addErrorFailureStructToHash(
                'behaviorErrors', $suite->{'exception'}, $errorStruct);
        }
    }
}

# Obtain LongName of a file
sub getLongName
{
    my $fileName = shift;

    for my $longName (keys %codeMarkupIds)
    {
        if (index(lc($longName),lc($fileName)) != -1)
        {
            return $longName;
        }
    }
    return undef;
}

# generate StackOverflowError struct
sub generateStackOverflowErrorStruct
{
    my $stackTrace = shift;
    my $errorStructFileName = undef;
    my $errorStructLineNum = undef;
    my $errorStructMessage = '';

    # We generate hint error struct in this case
    if (not defined $stackTrace)
    {
        return undef;
    }

    my @stackTracelines = split /\n/, $stackTrace;
    my %cyclesInStack = ();
    my $cycle = '';

    for my $line (@stackTracelines)
    {
        # Lines which contain this substring(example: (abc.java:102)) are
        # our required ones.
        if (index($line,"(") == -1 || index($line,")") == -1)
        {
            next;
        }

        my $tempFileDetails = substr($line, index($line, '(') + 1,
            index($line, ')') - index($line, '(') - 1);

        my @fileDetails = split(':', $tempFileDetails);
        my $tempSize = @fileDetails;
        if ($tempSize < 2)
        {
            next;
        }
        my $tempFileName = $fileDetails[0];

        my $fileName = undef;

        for my $longName (keys %codeMarkupIds)
        {
            if (index(lc($longName), lc($tempFileName)) != -1)
            {
                $fileName = $longName;
                last;
            }
        }

        if (!defined $fileName)
        {
            next;
        }

        # A cycle is found
        if (index(lc($cycle), lc($tempFileDetails)) != -1)
        {
            $cycle = substr($cycle, index(lc($cycle), lc($tempFileDetails)));
            $cycle .= '->';
            $cycle .= $tempFileDetails;

            if (defined $cyclesInStack{$cycle})
            {
                $cyclesInStack{$cycle}++;
            }
            else
            {
                $cyclesInStack{$cycle} = 1;
            }
            $cycle = '';
        }
        else
        {
            # Form calling order
            $cycle .= '->';
            $cycle .= $tempFileDetails;
        }
    }

    my $cyclesCount = keys %cyclesInStack;
    if ($cyclesCount == 0)
    {
        return undef;
    }

    foreach my $key (sort {$cyclesInStack{$b} <=> $cyclesInStack{$a}}
        keys %cyclesInStack)
    {
        my @cycleDetails = split('->', $key);
        # So that we print the cycle in actual calling order: bottom to top
        # in stack
        @cycleDetails = reverse @cycleDetails;
        my @fileDetails = split(':', $cycleDetails[0]);

        if (!defined $errorStructFileName || !defined $errorStructLineNum)
        {
            $errorStructFileName = getLongName($fileDetails[0]);
            $errorStructLineNum = $fileDetails[1];
        }

        my $methodCallsCount = @cycleDetails;
        if ($methodCallsCount == 2)
        {
            $errorStructMessage .=
                "The recursive method fails to stop calling itself:\n";
        }
        else
        {
           $errorStructMessage .=
               "There is a recursion with cyclic relationships:\n";
        }

        foreach my $methodIndex (0 .. $#cycleDetails)
        {
            @fileDetails = split(':', $cycleDetails[$methodIndex]);
            $errorStructMessage .= $fileDetails[0] . ':'
                . extractLineOfCode(
                getLongName($fileDetails[0]), $fileDetails[1]);
            $errorStructMessage =~ tr/ //s;
            chomp($errorStructMessage);

            if ($methodIndex != $methodCallsCount - 1)
            {
                $errorStructMessage .= '   ->   ';
            }
        }

        $errorStructMessage .= "\n";
    }

    return generateCompleteErrorStruct(
        $errorStructFileName, $errorStructLineNum, $errorStructMessage);
}


# topFileName is a boolean with '1' signifying topmost fileName and '0'
# signifying bottommost
sub extractFileNameFromStackTrace
{
    my $stackTrace = shift;

    if (!defined $stackTrace)
    {
        return (undef,undef);
    }

    my $topFileName = shift;

    my $fileName = undef;
    my $lineNum = undef;

    my @stackTracelines = split /\n/, $stackTrace;

    foreach my $line (@stackTracelines)
    {
        # Lines which contain this substring(example: (abc.java:102)) are
        # our required ones.
        if (index($line,"(") == -1 || index($line,")") == -1)
        {
            next;
        }

        my $tempFileDetails = substr($line, index($line, '(') + 1,
            index($line, ')') - index($line, '(') - 1);

        my @fileDetails = split(':', $tempFileDetails);
        my $tempSize = @fileDetails;
        if ($tempSize < 2)
        {
            next;
        }

        my $tempFileName = $fileDetails[0];
        my $tempLineNum = $fileDetails[1];

       for my $longName (keys %codeMarkupIds)
       {
            if (index(lc($longName), lc($tempFileName)) != -1)
            {
                $fileName = $longName;
                $lineNum = $tempLineNum;
                if ($topFileName == 1)
                {
                    last;
                }
            }
        }
    }

    return ($fileName, $lineNum);
}

@{$codingSectionExpanded{'codingFlaws'}} =
    addStructsToExpandedSectionsFromArrayHashValues('codingFlaws');
@{$codingSectionExpanded{'junitTests'}} =
    addStructsToExpandedSectionsFromArrayHashValues('junitTests');
@{$codingSectionExpanded{'signatureErrors'}} =
    addStructsToExpandedSectionsFromArrayHashValues('signatureErrors');

@{$testingSectionExpanded{'errors'}} =
    addStructsToExpandedSectionsFromArrayHashValues('errors');
@{$testingSectionExpanded{'failures'}} =
    addStructsToExpandedSectionsFromArrayHashValues('failures');
@{$testingSectionExpanded{'methodsUncovered'}} =
    addStructsToExpandedSectionsFromScalarHashValues('methodsUncovered');
@{$testingSectionExpanded{'conditionsUncovered'}} =
    addStructsToExpandedSectionsFromScalarHashValues('conditionsUncovered');
@{$testingSectionExpanded{'statementsUncovered'}} =
    addStructsToExpandedSectionsFromScalarHashValues('statementsUncovered');

@{$behaviorSectionExpanded{'errors'}} =
    addStructsToExpandedSectionsFromArrayHashValues('behaviorErrors');
@{$behaviorSectionExpanded{'failures'}} =
    addStructsToExpandedSectionsFromArrayHashValues('behaviorFailures');
@{$behaviorSectionExpanded{'stackOverflowErrors'}} =
    addStructsToExpandedSectionsFromArrayHashValues('stackOverflowErrors');
@{$behaviorSectionExpanded{'outOfMemoryErrors'}} =
    addStructsToExpandedSectionsFromArrayHashValues('outOfMemoryErrors');
@{$behaviorSectionExpanded{'testsTakeTooLong'}} =
    addStructsToExpandedSectionsFromArrayHashValues('testsTakeTooLong');

@{$styleSectionExpanded{'javadoc'}} =
    addStructsToExpandedSectionsFromArrayHashValues('javadoc');
@{$styleSectionExpanded{'indentation'}} =
    addStructsToExpandedSectionsFromArrayHashValues('indentation');
@{$styleSectionExpanded{'whitespace'}} =
    addStructsToExpandedSectionsFromArrayHashValues('whitespace');
@{$styleSectionExpanded{'lineLength'}} =
    addStructsToExpandedSectionsFromArrayHashValues('lineLength');
@{$styleSectionExpanded{'other'}} =
    addStructsToExpandedSectionsFromArrayHashValues('other');

#Group the errors by filename and limit them to $maxErrorsPerSubcategory
# Others have been grouped by subcategory, so we dont group by filename
@{$codingSectionExpanded{'signatureErrors'}} =
    groupStructsByFileName(\@{$codingSectionExpanded{'signatureErrors'}});
# @{$codingSectionExpanded{'signatureErrors'}} =
#     limitStructsInSubCategory(\@{$codingSectionExpanded{'signatureErrors'}});

@{$testingSectionExpanded{'errors'}} =
    groupStructsByFileName(\@{$testingSectionExpanded{'errors'}});
@{$testingSectionExpanded{'failures'}} =
    groupStructsByFileName(\@{$testingSectionExpanded{'failures'}});
# @{$testingSectionExpanded{'failures'}} =
#     limitStructsInSubCategory(\@{$testingSectionExpanded{'failures'}});

@{$testingSectionExpanded{'methodsUncovered'}} =
    groupStructsByFileName(\@{$testingSectionExpanded{'methodsUncovered'}});
# @{$testingSectionExpanded{'methodsUncovered'}} =
#   limitStructsInSubCategory(\@{$testingSectionExpanded{'methodsUncovered'}});
@{$testingSectionExpanded{'conditionsUncovered'}} =
    groupStructsByFileName(\@{$testingSectionExpanded{'conditionsUncovered'}});
@{$testingSectionExpanded{'conditionsUncovered'}} =
    limitStructsInSubCategory(
    \@{$testingSectionExpanded{'conditionsUncovered'}});
@{$testingSectionExpanded{'statementsUncovered'}} =
    groupStructsByFileName(\@{$testingSectionExpanded{'statementsUncovered'}});
@{$testingSectionExpanded{'statementsUncovered'}} =
    limitStructsInSubCategory(
    \@{$testingSectionExpanded{'statementsUncovered'}});

@{$behaviorSectionExpanded{'failures'}} =
    groupStructsByFileName(\@{$behaviorSectionExpanded{'failures'}});
# @{$behaviorSectionExpanded{'failures'}} =
#     limitStructsInSubCategory(\@{$behaviorSectionExpanded{'failures'}});
@{$behaviorSectionExpanded{'stackOverflowErrors'}} =
    groupStructsByFileName(\@{$behaviorSectionExpanded{'stackOverflowErrors'}});
# @{$behaviorSectionExpanded{'stackOverflowErrors'}} =
#     limitStructsInSubCategory(
#     \@{$behaviorSectionExpanded{'stackOverflowErrors'}});
@{$behaviorSectionExpanded{'outOfMemoryErrors'}} =
    groupStructsByFileName(\@{$behaviorSectionExpanded{'outOfMemoryErrors'}});
# @{$behaviorSectionExpanded{'outOfMemoryErrors'}} =
#     limitStructsInSubCategory(
#     \@{$behaviorSectionExpanded{'outOfMemoryErrors'}});
@{$behaviorSectionExpanded{'testsTakeTooLong'}} =
    groupStructsByFileName(\@{$behaviorSectionExpanded{'testsTakeTooLong'}});
# @{$behaviorSectionExpanded{'testsTakeTooLong'}} =
#     limitStructsInSubCategory(
#     \@{$behaviorSectionExpanded{'testsTakeTooLong'}});

@{$styleSectionExpanded{'javadoc'}} =
    groupStructsByFileName(\@{$styleSectionExpanded{'javadoc'}});
@{$styleSectionExpanded{'javadoc'}} =
    limitStructsInSubCategory(\@{$styleSectionExpanded{'javadoc'}});
@{$styleSectionExpanded{'indentation'}} =
    groupStructsByFileName(\@{$styleSectionExpanded{'indentation'}});
@{$styleSectionExpanded{'indentation'}} =
    limitStructsInSubCategory(\@{$styleSectionExpanded{'indentation'}});
@{$styleSectionExpanded{'whitespace'}} =
    groupStructsByFileName(\@{$styleSectionExpanded{'whitespace'}});
@{$styleSectionExpanded{'whitespace'}} =
    limitStructsInSubCategory(\@{$styleSectionExpanded{'whitespace'}});
@{$styleSectionExpanded{'lineLength'}} =
    groupStructsByFileName(\@{$styleSectionExpanded{'lineLength'}});
@{$styleSectionExpanded{'lineLength'}} =
    limitStructsInSubCategory(\@{$styleSectionExpanded{'lineLength'}});
@{$styleSectionExpanded{'other'}} =
    groupStructsByFileName(\@{$styleSectionExpanded{'other'}});
@{$styleSectionExpanded{'other'}} =
    limitStructsInSubCategory(\@{$styleSectionExpanded{'other'}});

#To limit number of error structs in a subcategory to $maxErrorsPerSubcategory
sub limitStructsInSubCategory {
    my $arrayRef = shift;
    my @arrayStructs = @{$arrayRef};
    my @expandedMessageStruct;

    my $errorsPerRule = $maxErrorsPerSubcategory;
    my $arraySize = @arrayStructs;

    while ($errorsPerRule > 0 && $arraySize > 0) {
        my $struct = shift @arrayStructs;
        push @expandedMessageStruct, $struct;

        $errorsPerRule--;
        $arraySize--;
    }

    if ($arraySize == 0) {
        return @expandedMessageStruct;
    }

    push @expandedMessageStruct, countErrorsPerFileOverLimit(\@arrayStructs);

    return @expandedMessageStruct;
}

#Create a string which contains the count of errors which we don't display in the feedback
#Store that string in the errorStruct as part of enhanced message
sub countErrorsPerFileOverLimit {
    my $arrayRef = shift;
    my @arrayStructs = @{$arrayRef};

    my %countPerFile;
    foreach my $struct (@arrayStructs) {
        if (defined $countPerFile{$struct->entityName}) {
            $countPerFile{$struct->entityName}++;
        } else {
            $countPerFile{$struct->entityName} = 1;
        }
    }

    my $moreErrorString = "Likewise, there are ";

    my $fileCount = keys %countPerFile;
    foreach my $file (sort { $countPerFile{$b} <=> $countPerFile{$a} } keys %countPerFile) {
        $moreErrorString .= $countPerFile{$file} . " issue(s) in " . $file . ", ";
    }

    #Remove the last ", ".
    chop($moreErrorString);
    chop($moreErrorString);
    $moreErrorString .= ".";

    my $moreErrorsStruct = expandedMessage->new( entityName => '',
                        lineNum => '',
                        errorMessage => '',
                        linesOfCode => '',
                        enhancedMessage => $moreErrorString,
                        );

    return $moreErrorsStruct;
}

# To group all the structs based on fileName(sorted)
sub groupStructsByFileName
{
    my $arrayRef = shift;
    my @arrayStructs = @{$arrayRef};
    my %fileStructs;
    my @groupedStructs;

    foreach my $errorStruct (@arrayStructs)
    {
        if (defined $fileStructs{$errorStruct->entityName})
        {
            push @{$fileStructs{$errorStruct->entityName}}, $errorStruct;
        }
        else
        {
            my @temp;
            push @temp, $errorStruct;
            $fileStructs{$errorStruct->entityName} = [@temp];
        }
    }

    foreach my $entityName (sort keys %fileStructs)
    {
        my %lineStructs;

        foreach my $errorStruct (@{$fileStructs{$entityName}})
        {
            if (defined $lineStructs{$errorStruct->lineNum})
            {
                push @{$lineStructs{$errorStruct->lineNum}}, $errorStruct;
            }
            else
            {
                my @temp;
                push @temp, $errorStruct;
                $lineStructs{$errorStruct->lineNum} = [@temp];
            }
        }

        foreach my $lineNum (sort {$a<=>$b} keys %lineStructs)
        {
            push @groupedStructs, @{$lineStructs{$lineNum}};
        }
    }

    return @groupedStructs;
}




my $beautifier = new Web_CAT::Beautifier;
$beautifier->setCountLoc(1);
$beautifier->beautifyCwd($cfg,
    \@beautifierIgnoreFiles,
    \%codeMarkupIds,
    \%codeMessages
    );


#=============================================================================
# generate score
#=============================================================================

# First, the static analysis, tool-based score
my $staticScore  = $maxToolScore - $status{'toolDeductions'};
my $show_gzoltar = ($instructorCasesPercent < 10) ? 0 : 1;

# Second, the coverage/testing/correctness component
my $runtimeScore = $runtimeScoreWithoutCoverage;
if ($studentsMustSubmitTests)
{
    if ($gradedElements > 0)
    {
        my $multiplier = $gradedElementsCovered * 1.0 / $gradedElements
            / $coverageGoal;
        if ($multiplier * 100.0 < $minCoverageLevel)
        {
            # print "multiplier = $multiplier\n";
            $show_gzoltar = 0;
        }
        if ($multiplier < 1.0)
        {
            $runtimeScore *= $multiplier;
        }
    }
    else
    {
        $runtimeScore = 0;
    }
}

print "score with coverage: $runtimeScore ($gradedElementsCovered "
    . "elements / $gradedElements covered)\n" if ($debug > 2);

# Total them up
# my $rawScore = $can_proceed
#     ? ($staticScore + $runtimeScore)
#     : 0;


#=============================================================================
# Include zoltar info, if present.
#=============================================================================

my $gzoltar_file = "${resultDir}/gzoltar.html";
# print "instructor cases = $instructorCasesPercent, show = $show_gzoltar\n";
if ($show_gzoltar && -f $gzoltar_file && ! -z $gzoltar_file)
{
    # print "starting feedback section\n";
    $status{'feedback'}->startFeedbackSection(
        "Heatmap of Suspicious Code",
        ++$expSectionId);
    $status{'feedback'}->print(<<EOF);
<p>
This color-coded view of your source code shows the <b>most suspicious</b>
areas in your program--the lines that are most strongly associated with
failing reference tests provided by your instructor.</p>
<p>
The lines highlighted in color are hints for place(s) you can look for
bugs, with lines that are darker or more red being more suspicious.  Only
classes containing suspicious lines are shown.</p>
<p>
Hover your mouse over colored lines to see line numbers.</p>
EOF
    open(GZOLTAR, $gzoltar_file);
    my $line;
    while ($line = <GZOLTAR>)
    {
        $status{'feedback'}->print($line);
    }
    close(GZOLTAR);
    $status{'feedback'}->endFeedbackSection;
}


#=============================================================================
# generate score explanation for student
#=============================================================================
if ($can_proceed && $studentsMustSubmitTests)
{
    my $scoreToTenths = int($runtimeScore * 10 + 0.5) / 10;
    my $possible = int($maxCorrectnessScore * 10 + 0.5) / 10;
    $status{'feedback'}->startFeedbackSection(
        "Interpreting Your Correctness/Testing Score "
        . "($scoreToTenths/$possible)",
        ++$expSectionId,
        1);
    $status{'feedback'}->print(<<EOF);
<table style="border:none">
<tr><td><b>Results from running your tests:</b></td>
<td class="n">$studentCasesPercent%</td></tr>
<tr><td><b>Code coverage from your tests:</b></td>
<td class="n">$codeCoveragePercent%</td></tr>
<tr><td><b>Estimate of problem coverage:</b></td>
<td class="n">$instructorCasesPercent%</td></tr>
<tr><td colspan="2">score =
$studentCasesPercent%
* $codeCoveragePercent%
* $instructorCasesPercent%
* $maxCorrectnessScore
points possible = $scoreToTenths</p>
</table>
<p>Full-precision (unrounded) percentages are used to calculate
your score, not the rounded numbers shown above.</p>
EOF
    $status{'feedback'}->endFeedbackSection;
}


#=============================================================================
# Include COMTOR results, if any
#=============================================================================
if (-f "$resultDir/comtor.html")
{
    open(COMTORRESULTS, "$resultDir/comtor.html");
    my @lines = <COMTORRESULTS>;
    close(COMTORRESULTS);
#    my $inBody = 0;
    $status{'feedback'}->startFeedbackSection(
        "COMTOR Comment Analysis", ++$expSectionId, 1);
    $status{'feedback'}->print('<div class="comtor">');
    $status{'feedback'}->print(@lines);
#    foreach my $line (@lines)
#    {
#        if ($line =~ s/^.*<body>//io)
#        {
#            $inBody = 1;
#        }
#        if ($inBody)
#        {
#            if ($line =~ s/<\/body>.*$//io)
#            {
#               $inBody = 0;
#            }
#            $status{'feedback'}->print($line);
#        }
#    }
    $status{'feedback'}->print('</div>');
    $status{'feedback'}->endFeedbackSection;
}


#=============================================================================
# generate collapsible section for class diagrams
#=============================================================================
if (-d $diagrams && scalar <$diagrams/*>)
{
    $status{'feedback'}->startFeedbackSection(
        "Graphical Representation of Your Class Design",
        ++$expSectionId);
    $status{'feedback'}->print(<<EOF);
<p>The images below present a graphical representation of your
solution's class design. An arrow pointing from <b>B</b> to
<b>A</b> means that <b>B</b> extends/implements <b>A</b>. These
diagrams are provided for your benefit as well as for the course
staff to refer to when grading.</p>
<div style="border: 1px solid gray; background-color: white; padding: 1em">
EOF
    opendir my($dirhandle), $diagrams;
    my @diagramFiles = readdir $dirhandle;
    closedir $dirhandle;

    for my $diagramFile (@diagramFiles)
    {
        if ($diagramFile !~ /^\..*/)
        {
            my $url = "\${publicResourceURL}/diagrams/$diagramFile";
            $status{'feedback'}->print(
                "<span style=\"margin-right: 1em\">"
                . "<img src=\"$url\"/></span>\n");
        }
    }

    $status{'feedback'}->print('</div>');
    $status{'feedback'}->endFeedbackSection;
}


#=============================================================================
# Update and rewrite properties to reflect status
#=============================================================================

# Student feedback
# -----------
{
    my $rptFile = $status{'feedback'};
    if (defined $rptFile)
    {
        $rptFile->close;
        if ($rptFile->hasContent)
        {
            if ($useEnhancedFeedback)
            {
                addReportFileWithStyle(
                    $cfg, 'improvedFeedback.html', 'text/html', 1);
            }
            addReportFileWithStyle($cfg, $rptFile->fileName, 'text/html', 1);
        }
        else
        {
            $rptFile->unlink;
        }
    }
}

# Instructor feedback
# -----------
{
    my $rptFile = $status{'instrFeedback'};
    if (defined $rptFile)
    {
        $rptFile->close;
        if ($rptFile->hasContent)
        {
            addReportFileWithStyle(
                $cfg, $rptFile->fileName, 'text/html', 1, 'staff');
        }
        else
        {
            $rptFile->unlink;
        }
    }
}

# Figure out which section among coding(1), testing(2), behavior(3) and
# style(4) to expand
sub computeExpandSectionId
{
    if ($codingSectionStatus{'compilerErrors'} == 0
        || $codingSectionStatus{'compilerWarnings'} == 0
        || $codingSectionStatus{'signatureErrors'} == 0
        || $codingSectionStatus{'codingFlaws'} == 0
        || $codingSectionStatus{'junitTests'} == 0)
    {
        return 1;
    }

    if ($testingSectionStatus{'errors'} == 0 ||
        $testingSectionStatus{'failures'} == 0 ||
        $testingSectionStatus{'methodsUncovered'} == 0 ||
        $testingSectionStatus{'statementsUncovered'} == 0 ||
        $testingSectionStatus{'conditionsUncovered'} == 0)
    {
        return 2;
    }

    if ($behaviorSectionStatus{'errors'} == 0
        || $behaviorSectionStatus{'stackOverflowErrors'} == 0
        || $behaviorSectionStatus{'testsTakeTooLong'} == 0
        || $behaviorSectionStatus{'failures'} == 0
        || $behaviorSectionStatus{'outOfMemoryErrors'} == 0)
    {
        return 3;
    }

    if ($styleSectionStatus{'javadoc'} == 0
        || $styleSectionStatus{'indentation'} == 0
        || $styleSectionStatus{'whitespace'} == 0
        || $styleSectionStatus{'lineLength'} == 0
        || $styleSectionStatus{'other'} == 0)
    {
        return 4;
    }

    return -1;
}

# If Compiler Errors- set all other section status to "-1" (no tick or cross
# mark). set others to "-1" so that we don't mark anything for others as we
# didnt evaluate.
if ($codingSectionStatus{'compilerErrors'} == 0)
{
    $codingSectionStatus{'codingFlaws'} = -1;
    $codingSectionStatus{'signatureErrors'} = -1;
    $codingSectionStatus{'junitTests'} = -1;

    $styleSectionStatus{'javadoc'} = -1;
    $styleSectionStatus{'indentation'} = -1;
    $styleSectionStatus{'whitespace'} = -1;
    $styleSectionStatus{'lineLength'} = -1;
    $styleSectionStatus{'other'} = -1;

    $testingSectionStatus{'errors'} = -1;
    $testingSectionStatus{'failures'} = -1;
    $testingSectionStatus{'methodsUncovered'} = -1;
    $testingSectionStatus{'statementsUncovered'} = -1;
    $testingSectionStatus{'conditionsUncovered'} = -1;

    $behaviorSectionStatus{'errors'} = -1;
    $behaviorSectionStatus{'stackOverflowErrors'} = -1;
    $behaviorSectionStatus{'testsTakeTooLong'} = -1;
    $behaviorSectionStatus{'failures'} = -1;
    $behaviorSectionStatus{'outOfMemoryErrors'} = -1;
}

# set expand section id for web-cat sections (coding,testing,behavior, style)
$expandSectionId = computeExpandSectionId();


# Compute Radial Bars for Coding Section
if ($codingSectionStatus{'compilerErrors'} == 1
    && $codingSectionStatus{'compilerWarnings'} == 1
    && $codingSectionStatus{'signatureErrors'} == 1)
{
    $codingSectionStatus{'firstHalfRadialBar'} = 50;
}
else
{
    $codingSectionStatus{'firstHalfRadialBar'} = 0;
}

if ($codingSectionStatus{'codingFlaws'} == 1
    && $codingSectionStatus{'junitTests'} == 1)
{
    $codingSectionStatus{'secondHalfRadialBar'} = 50;
}
else
{
    $codingSectionStatus{'secondHalfRadialBar'} = 0;
}

# Generate Feedback section html
my $improvedFeedbackFileName = "$resultDir/improvedFeedback.html";
open(IMPROVEDFEEDBACKFILE, ">$improvedFeedbackFileName")
    || croak "Cannot open '$improvedFeedbackFileName' for writing: $!";


# UserName
print IMPROVEDFEEDBACKFILE
    '<input type="hidden" id="userName" name="userName" value="' . $pid . '">';

# Coding Section
my $incomplete = ($expandSectionId == 1) ? ' incomplete' : '';
print IMPROVEDFEEDBACKFILE <<END_MESSAGE;
<div class="row">
  <div class="col-12 col-md-6 panel$incomplete" id="codingPanel">
    <div class="module">
      <div dojoType="webcat.TitlePane" title="Coding">
    <style>
      \@keyframes rotate-coding {
        100% {
END_MESSAGE

print IMPROVEDFEEDBACKFILE
    'transform: rotate(' . 180 * ($codingSectionStatus{'firstHalfRadialBar'}
    + $codingSectionStatus{'secondHalfRadialBar'}) / 100 . 'deg);';

print IMPROVEDFEEDBACKFILE <<END_MESSAGE;
        }
      }
     </style>
    <ul class="chart" id="codingChart">
END_MESSAGE

# Values going into the spans don't add any meaning; adding two spans for
# css sake
print IMPROVEDFEEDBACKFILE '<li><span>',
    "$codingSectionStatus{'firstHalfRadialBar'}%", '</span></li>',
    '<li><span>',
    "$codingSectionStatus{'secondHalfRadialBar'}%", '</span></li>',
    "</ul>\n<ul class=\"checklist\">\n";

for my $element (@codingSectionOrder)
{
    my $cssClass = ($codingSectionStatus{$element} == 1)
        ? 'complete'
        : (($codingSectionStatus{$element} == 0) ? 'incomplete' : 'unknown');

    print IMPROVEDFEEDBACKFILE '<li class="', $cssClass, '">',
        ($codingSectionStatus{$element} == 0 ? '' : 'No '),
        "$codingSectionTitles{$element}</li>";
}

print IMPROVEDFEEDBACKFILE "</ul>\n";

if ($codingSectionStatus{'compilerErrors'} == 0
    || $codingSectionStatus{'compilerWarnings'} == 0
    || $codingSectionStatus{'signatureErrors'} == 0
    || $codingSectionStatus{'codingFlaws'} == 0
    || $codingSectionStatus{'junitTests'} == 0)
{
    print IMPROVEDFEEDBACKFILE '<span class="seeMoreButton"><a ',
        'class="seeMoreLink btn btn-sm btn-primary" ',
        'href="#codingPanel">More...</a></span>';
}


# Coding Section Expanded
my $isVisible = ($expandSectionId == 1) ? ' visible' : '';
print IMPROVEDFEEDBACKFILE <<END_MESSAGE;
      </div>
      <div class="arrow borderArrow codingarrow$isVisible"></div>
      <div class="arrow codingarrow$isVisible"></div>
    </div>
  </div>
END_MESSAGE
if ($codingSectionStatus{'compilerErrors'} == 0
    || $codingSectionStatus{'compilerWarnings'} == 0
    || $codingSectionStatus{'signatureErrors'} == 0
    || $codingSectionStatus{'codingFlaws'} == 0
    || $codingSectionStatus{'junitTests'} == 0)
{
print IMPROVEDFEEDBACKFILE <<END_MESSAGE;
<div class="col-12 more-info$isVisible" id="coding-moreInfo">
  <div class="module">
END_MESSAGE

for my $element (@codingSectionOrder)
{
    if (!defined $codingSectionExpanded{$element}
        || !@{$codingSectionExpanded{$element}})
    {
        next;
    }

    print IMPROVEDFEEDBACKFILE
        '<h1>' . $codingSectionTitles{$element} . '</h1>' ;

    foreach my $errorStruct (@{$codingSectionExpanded{$element}})
    {
        print IMPROVEDFEEDBACKFILE
            '<h2>', $errorStruct->entityName, '</h2><p class="errorType">',
            htmlEscape($errorStruct->errorMessage), '</p>';

        if (index(lc($element), lc('compilerErrors')) != -1)
        {
            print IMPROVEDFEEDBACKFILE '<input type="hidden" ',
                'name="compilerErrorId" value="',
                compilerErrorHintKey($errorStruct->errorMessage), '"/>';
        }
        elsif (index(lc($element), lc('signatureErrors')) != -1)
        {
            print IMPROVEDFEEDBACKFILE
                '<input type="hidden" name="runtimeErrorId" value="',
                runtimeErrorHintKey($errorStruct->errorMessage), '"/>';
        }

        my @linesOfCode = split /\n/, $errorStruct->linesOfCode;

        if ( @linesOfCode)
        {
            print IMPROVEDFEEDBACKFILE '<pre class="prettyprint lang-java">',
                "\n";

            foreach my $line (@linesOfCode)
            {
                if (index(lc($line), $errorStruct->lineNum) != -1)
                {
                    print IMPROVEDFEEDBACKFILE
                        '<span class="nocode highlight">', htmlEscape($line),
                        '</span>', "\n";
                    next;
                }

                print IMPROVEDFEEDBACKFILE htmlEscape($line), "\n";
            }

            print IMPROVEDFEEDBACKFILE '</pre>';
        }

        if ($errorStruct->enhancedMessage)
        {
            print IMPROVEDFEEDBACKFILE '<p><span>',
                htmlEscape($errorStruct->enhancedMessage), '</span></p>';
        }
    }
}

print IMPROVEDFEEDBACKFILE <<END_MESSAGE;
  </div>
</div>
END_MESSAGE
}


if ($codingSectionStatus{'compilerErrors'} == 1 && $studentsMustSubmitTests)
{
# Testing Section
my $showTesting = 1;
my $testingMsg = '';
if ($status{'studentTestResults'}->testsExecuted == 0)
{
    $showTesting = 0;
    $expandSectionId = 2;
    $testingMsg = '<p>You are required to write your own software tests '
        . 'for this assignment, but <b class="warn">no tests were '
        . 'provided</b>.</p>';
}
$incomplete = ($expandSectionId == 2) ? ' incomplete' : '';
print IMPROVEDFEEDBACKFILE <<END_MESSAGE;
  <div class="col-12 col-md-6 panel$incomplete" id="testingPanel">
    <div class="module">
      <div dojoType="webcat.TitlePane" title="Your Testing">
END_MESSAGE
if ($showTesting)
{
print IMPROVEDFEEDBACKFILE <<END_MESSAGE;
    <style>
      \@keyframes rotate-testing {
        100% {
END_MESSAGE

my $testingPct = ($testingSectionStatus{'codeCoveragePercent'}
    * $testingSectionStatus{'resultsPercent'}) / 100;
print IMPROVEDFEEDBACKFILE 'transform: rotate(' .
    180 * $testingPct / 100 . 'deg);';

print IMPROVEDFEEDBACKFILE <<END_MESSAGE;
        }
      }
     </style>
    <ul class="chart" id="testingChart">
END_MESSAGE

# Values going into the spans don't add any meaning; adding two spans for
# css sake
my $roundedPct = int ($testingPct + 0.5);
if ($roundedPct == 100 && $testingPct < 100)
{
    $roundedPct--;
}
if ($roundedPct < 10)
{
    $roundedPct = "&nbsp;$roundedPct";
}
print IMPROVEDFEEDBACKFILE '<li><span>',
    $testingPct, '%</span></li>',
    '<li><span>', $testingPct, '%</span></li><span class="percentage">',
    $roundedPct, '%</span>', "</ul>\n";
}
print IMPROVEDFEEDBACKFILE "<ul class=\"checklist\">\n";

for my $element (@testingSectionOrder)
{
    my $cssClass = ($testingSectionStatus{$element} == 1)
        ? 'complete'
        : (($testingSectionStatus{$element} == 0) ? 'incomplete' : 'unknown');
    if (!$showTesting) { $cssClass = 'unknown'; }
    print IMPROVEDFEEDBACKFILE '<li class="', $cssClass, '">',
        ($testingSectionStatus{$element} == 0 ? '' : 'No '),
        "$testingSectionTitles{$element}</li>";
}

print IMPROVEDFEEDBACKFILE "</ul>\n";

if ($testingSectionStatus{'errors'} == 0
    || $testingSectionStatus{'failures'} == 0
    || $testingSectionStatus{'methodsUncovered'} == 0
    || $testingSectionStatus{'statementsUncovered'} == 0
    || $testingSectionStatus{'conditionsUncovered'} == 0 )
{
    print IMPROVEDFEEDBACKFILE '<span class="seeMoreButton"><a ',
        'class="seeMoreLink btn btn-sm btn-primary" ',
        'href="#testingPanel">More...</a></span>';
}


# Testing Section Expanded
$isVisible = ($expandSectionId == 2) ? ' visible' : '';
print IMPROVEDFEEDBACKFILE <<END_MESSAGE;
      $testingMsg</div>
      <div class="arrow borderArrow testingarrow$isVisible"></div>
      <div class="arrow testingarrow$isVisible"></div>
    </div>
  </div>
END_MESSAGE
if ($codingSectionStatus{'compilerErrors'} == 1 && $studentsMustSubmitTests &&
    ($testingSectionStatus{'errors'} == 0
    || $testingSectionStatus{'failures'} == 0
    || $testingSectionStatus{'methodsUncovered'} == 0
    || $testingSectionStatus{'statementsUncovered'} == 0
    || $testingSectionStatus{'conditionsUncovered'} == 0 ))
{
print IMPROVEDFEEDBACKFILE <<END_MESSAGE;
<div class="col-12 more-info$isVisible" id="testing-moreInfo">
  <div class="module">
END_MESSAGE

for my $element (@testingSectionOrder)
{
    if (!defined $testingSectionExpanded{$element}
        || !@{$testingSectionExpanded{$element}})
    {
        next;
    }

    print IMPROVEDFEEDBACKFILE
        '<h1>', $testingSectionTitles{$element}, '</h1>';

    foreach my $errorStruct (@{$testingSectionExpanded{$element}})
    {
        print IMPROVEDFEEDBACKFILE '<h2>', $errorStruct->entityName, '</h2>',
            '<p class="errorType">', htmlEscape($errorStruct->errorMessage),
            '</p>';

        if (index(lc($element), lc("errors")) != -1)
        {
            print IMPROVEDFEEDBACKFILE
                '<input type="hidden" name="runtimeErrorId" value="',
                runtimeErrorHintKey($errorStruct->errorMessage), '"/>';
        }

        my @linesOfCode = split /\n/, $errorStruct->linesOfCode;

        if (@linesOfCode)
        {
            print IMPROVEDFEEDBACKFILE '<pre class="prettyprint lang-java">',
                "\n";

            for my $index (0 .. $#linesOfCode)
            {
                if (index(lc($linesOfCode[$index]), $errorStruct->lineNum)
                    != -1)
                {
                    print IMPROVEDFEEDBACKFILE
                        '<span class="nocode highlight">',
                        htmlEscape($linesOfCode[$index]),
                        "</span>\n";
                    next;
                }

                # All statements uncovered are errors (except first and last),
                # so mark them as errors
                if (index(lc($element), "statement") != -1
                    && $index != 0
                    && $index != $#linesOfCode)
                {
                    print IMPROVEDFEEDBACKFILE
                        '<span class="nocode highlight">',
                        htmlEscape($linesOfCode[$index]),
                        "</span>\n";
                }
                else
                {
                    print IMPROVEDFEEDBACKFILE
                        htmlEscape($linesOfCode[$index]), "\n";
                }
            }

            print IMPROVEDFEEDBACKFILE '</pre>';
        }

        if ($errorStruct->enhancedMessage)
        {
            print IMPROVEDFEEDBACKFILE '<p><span>',
                htmlEscape($errorStruct->enhancedMessage), '</span></p>';
        }
    }
}

print IMPROVEDFEEDBACKFILE <<END_MESSAGE;
  </div>
</div>
END_MESSAGE
}


# Behavior Section
my $showBehavior = 1;
my $behaviorMsg = '';
if ($studentsMustSubmitTests)
{
    if ($hasJUnitErrors && $junitErrorsHideHints)
    {
        $showBehavior = 0;
        $behaviorMsg = '<p>Fix <b class="warn">Unit Test Coding Problems</b> '
            . '(see above) for behavioral analysis.</p>';
    }
    elsif ($status{'studentTestResults'}->testsExecuted == 0)
    {
        $showBehavior = 0;
        $behaviorMsg = '<p>Your own software tests must be included for '
            . 'behavioral analysis.</p>';
    }
    elsif (!$status{'studentTestResults'}->hasResults
           || $gradedElements == 0
           || $gradedElementsCovered / $gradedElements * 100.0 <
              $minCoverageLevel)
    {
        $showBehavior = 0;
        $behaviorMsg = '<p>I';
        if ($expandSectionId == 1)
        {
            $behaviorMsg = '<p>Fix the issues in the '
                . '<b class="warn">Coding</b> section above. Then i';
        }
        # Note the initial "I" comes from the earlier initialization
        $behaviorMsg .= 'mprove your testing by addressing issues in '
            . '<b class="warn">Your Testing</b> section '
            . 'above for behavioral analysis.</p>';
    }
}
$incomplete = ($expandSectionId == 3) ? ' incomplete' : '';
if (!$showBehavior) { $incomplete = ''; }
print IMPROVEDFEEDBACKFILE <<END_MESSAGE;
  <div class="col-12 col-md-6 panel$incomplete" id="behaviorPanel">
    <div class="module">
      <div dojoType="webcat.TitlePane" title="Behavior">
END_MESSAGE
if ($showBehavior)
{
print IMPROVEDFEEDBACKFILE <<END_MESSAGE;
    <style>
      \@keyframes rotate-behavior {
        100% {
END_MESSAGE

print IMPROVEDFEEDBACKFILE 'transform: rotate(' .
    180 * ($behaviorSectionStatus{'problemCoveragePercent'}) / 100 . 'deg);';

print IMPROVEDFEEDBACKFILE <<END_MESSAGE;
        }
      }
     </style>
    <ul class="chart" id="behaviorChart">
END_MESSAGE

# Values going into the spans don't add any meaning; adding two spans for
# css sake
my $roundedPct = int ($behaviorSectionStatus{'problemCoveragePercent'} + 0.5);
if ($roundedPct == 100 && $behaviorSectionStatus{'problemCoveragePercent'} < 100)
{
    $roundedPct--;
}
if ($roundedPct < 10)
{
    $roundedPct = "&nbsp;$roundedPct";
}
print IMPROVEDFEEDBACKFILE '<li><span>',
    $behaviorSectionStatus{'problemCoveragePercent'},
    '%</span></li><li><span>',
    $behaviorSectionStatus{'problemCoveragePercent'},
    '%</span></li><span class="percentage">',
    $roundedPct, '%</span>', "</ul>\n";
}
print IMPROVEDFEEDBACKFILE "<ul class=\"checklist\">\n";

for my $element (@behaviorSectionOrder)
{
    my $cssClass = ($behaviorSectionStatus{$element} == 1)
        ? 'complete'
        : (($behaviorSectionStatus{$element} == 0) ? 'incomplete' : 'unknown');
    if (!$showBehavior) { $cssClass = 'unknown'; }

    print IMPROVEDFEEDBACKFILE '<li class="', $cssClass, '">',
        ($behaviorSectionStatus{$element} == 0 ? '' : 'No '),
        "$behaviorSectionTitles{$element}</li>";
}

print IMPROVEDFEEDBACKFILE "</ul>\n";

if ($showBehavior
    && ($behaviorSectionStatus{'errors'} == 0
    || $behaviorSectionStatus{'stackOverflowErrors'} == 0
    || $behaviorSectionStatus{'testsTakeTooLong'} == 0
    || $behaviorSectionStatus{'failures'} == 0
    || $behaviorSectionStatus{'outOfMemoryErrors'} == 0))
{
    print IMPROVEDFEEDBACKFILE '<span class="seeMoreButton"><a ',
        'class="seeMoreLink btn btn-sm btn-primary" ',
        'href="#behaviorPanel">More...</a></span>';
}


# Behavior Section Expanded
$isVisible = ($expandSectionId == 3) ? ' visible' : '';
print IMPROVEDFEEDBACKFILE <<END_MESSAGE;
      $behaviorMsg</div>
      <div class="arrow borderArrow behaviorarrow$isVisible"></div>
      <div class="arrow behaviorarrow$isVisible"></div>
    </div>
  </div>
END_MESSAGE
if ($showBehavior
    && ($behaviorSectionStatus{'errors'} == 0
    || $behaviorSectionStatus{'stackOverflowErrors'} == 0
    || $behaviorSectionStatus{'testsTakeTooLong'} == 0
    || $behaviorSectionStatus{'failures'} == 0
    || $behaviorSectionStatus{'outOfMemoryErrors'} == 0))
{
print IMPROVEDFEEDBACKFILE <<END_MESSAGE;
<div class="col-12 more-info$isVisible" id="behavior-moreInfo">
  <div class="module">
END_MESSAGE


for my $element (@behaviorSectionOrder)
{
    if (!defined $behaviorSectionExpanded{$element}
        || !@{$behaviorSectionExpanded{$element}})
    {
        next;
    }

    print IMPROVEDFEEDBACKFILE
        '<h1>', $behaviorSectionTitles{$element}, '</h1>' ;

    if ($element eq 'failures')
    {
        print IMPROVEDFEEDBACKFILE '<p>Instructor reference tests found '
            . 'problems with the following features:</p>';
    }

    foreach my $errorStruct (@{$behaviorSectionExpanded{$element}})
    {
        print IMPROVEDFEEDBACKFILE '<h2>', $errorStruct->entityName, '</h2>',
            '<p class="errorType">', htmlEscape($errorStruct->errorMessage),
            '</p><input type="hidden" name="runtimeErrorId" value="',
            runtimeErrorHintKey($errorStruct->errorMessage), '"/>';

        my @linesOfCode = split /\n/, $errorStruct->linesOfCode;
        if (@linesOfCode)
        {
            print IMPROVEDFEEDBACKFILE '<pre class="prettyprint lang-java">',
                "\n";

            foreach my $line (@linesOfCode)
            {
                if (index(lc($line), $errorStruct->lineNum) != -1)
                {
                    print IMPROVEDFEEDBACKFILE
                        '<span class="nocode highlight">', htmlEscape($line),
                        '</span>', "\n";
                    next;
                }

                print IMPROVEDFEEDBACKFILE htmlEscape($line), "\n";
            }

            print IMPROVEDFEEDBACKFILE '</pre>';
        }

        if ($errorStruct->enhancedMessage)
        {
            print IMPROVEDFEEDBACKFILE '<p><span>',
                htmlEscape($errorStruct->enhancedMessage), '</span></p>';
        }
    }
}

print IMPROVEDFEEDBACKFILE <<END_MESSAGE;
  </div>
</div>
END_MESSAGE
}


#Style Section
$incomplete = ($expandSectionId == 4) ? ' incomplete' : '';
print IMPROVEDFEEDBACKFILE <<END_MESSAGE;
  <div class="col-12 col-md-6 panel$incomplete" id="stylePanel">
    <div class="module">
      <div dojoType="webcat.TitlePane" title="Style">
    <style>
      \@keyframes rotate-style {
        100% {
END_MESSAGE

print IMPROVEDFEEDBACKFILE 'transform: rotate('
    . 180 * ($styleSectionStatus{'pointsGainedPercent'}) / 100 . 'deg);';

print IMPROVEDFEEDBACKFILE <<END_MESSAGE;
        }
      }
     </style>
    <ul class="chart" id="styleChart">
END_MESSAGE

# Values going into the spans don't add any meaning; adding two spans for
# css sake
my $roundedPct = int ($styleSectionStatus{'pointsGainedPercent'} + 0.5);
if ($roundedPct == 100 && $styleSectionStatus{'pointsGainedPercent'} < 100)
{
    $roundedPct--;
}
if ($roundedPct < 10)
{
    $roundedPct = "&nbsp;$roundedPct";
}
print IMPROVEDFEEDBACKFILE '<li><span>',
    $styleSectionStatus{'pointsGainedPercent'}, '%</span></li><li><span>',
    $styleSectionStatus{'pointsGainedPercent'},
    '%</span></li><span class="percentage">',
    $roundedPct, '%</span>',
    "</ul>\n<ul class=\"checklist\">\n";

for my $element (@styleSectionOrder)
{
    my $cssClass = ($styleSectionStatus{$element} == 1)
        ? 'complete'
        : (($styleSectionStatus{$element} == 0) ? 'incomplete' : 'unknown');

    print IMPROVEDFEEDBACKFILE '<li class="', $cssClass, '">',
        ($styleSectionStatus{$element} == 0 ? '' : 'No '),
        "$styleSectionTitles{$element}</li>";
}

print IMPROVEDFEEDBACKFILE "</ul>\n";

if ($styleSectionStatus{'javadoc'} == 0
    || $styleSectionStatus{'indentation'} == 0
    || $styleSectionStatus{'whitespace'} == 0
    || $styleSectionStatus{'lineLength'} == 0
    || $styleSectionStatus{'other'} == 0)
{
    print IMPROVEDFEEDBACKFILE '<span class="seeMoreButton"><a ',
        'class="seeMoreLink btn btn-sm btn-primary" ',
        'href="#stylePanel">More...</a></span>';
}


# Style Section Expanded
$isVisible = ($expandSectionId == 4) ? ' visible' : '';
print IMPROVEDFEEDBACKFILE <<END_MESSAGE;
      </div>
      <div class="arrow borderArrow stylearrow$isVisible"></div>
      <div class="arrow stylearrow$isVisible"></div>
    </div>
  </div>
END_MESSAGE
if ($styleSectionStatus{'javadoc'} == 0
    || $styleSectionStatus{'indentation'} == 0
    || $styleSectionStatus{'whitespace'} == 0
    || $styleSectionStatus{'lineLength'} == 0
    || $styleSectionStatus{'other'} == 0)
{
print IMPROVEDFEEDBACKFILE <<END_MESSAGE;
<div class="col-12 more-info$isVisible" id="style-moreInfo">
  <div class="module">
END_MESSAGE

for my $element (@styleSectionOrder)
{
    if (!defined $styleSectionExpanded{$element}
        || !@{$styleSectionExpanded{$element}})
    {
        next;
    }

    print IMPROVEDFEEDBACKFILE
        '<h1>', $styleSectionTitles{$element}, '</h1>';

    foreach my $errorStruct (@{$styleSectionExpanded{$element}})
    {
        print IMPROVEDFEEDBACKFILE '<h2>', $errorStruct->entityName, '</h2>',
            '<p class="errorType">', htmlEscape($errorStruct->errorMessage),
            "</p>\n";

        my @linesOfCode = split /\n/, $errorStruct->linesOfCode;

        if (@linesOfCode)
        {
            print IMPROVEDFEEDBACKFILE '<pre class="prettyprint lang-java">',
                "\n";

            foreach my $line (@linesOfCode)
            {
                if (index(lc($line), $errorStruct->lineNum) != -1)
                {
                    print IMPROVEDFEEDBACKFILE
                        '<span class="nocode highlight">', htmlEscape($line),
                        '</span>', "\n";
                    next;
                }

                print IMPROVEDFEEDBACKFILE htmlEscape($line), "\n";
            }

            print IMPROVEDFEEDBACKFILE '</pre>';
        }

        if ($errorStruct->enhancedMessage)
        {
            print IMPROVEDFEEDBACKFILE '<p><span>',
                htmlEscape($errorStruct->enhancedMessage), '</span></p>';
        }
    }
}

print IMPROVEDFEEDBACKFILE <<END_MESSAGE;
  </div>
</div>
END_MESSAGE
}
}

print IMPROVEDFEEDBACKFILE "</div>\n";
close IMPROVEDFEEDBACKFILE;

#print compilerErrorHintKey('final parameter abc may not be assigned');

# PDF printout
# -----------
if (-f $pdfPrintout)
{
    addReportFileWithStyle(
        $cfg,
        $pdfPrintoutRelative,
        "application/pdf",
        1,
        undef,
        "false",
        "PDF code printout");
}

# Script log
# ----------
if (-f $scriptLog && stat($scriptLog)->size > 0)
{
    addReportFileWithStyle($cfg, $scriptLogRelative, "text/plain", 0, "admin");
    addReportFileWithStyle($cfg, $antLogRelative,    "text/plain", 0, "admin");
}

$cfg->setProperty('score.correctness', $runtimeScore);
$cfg->setProperty('score.tools',       $staticScore );
$cfg->setProperty('expSectionId',      $expSectionId);
$cfg->save();

if ($debug)
{
    my $lasttime = time;
    print "\n", ($lasttime - $time1), " seconds total\n";
    print "\nFinal properties:\n-----------------\n";
    my $props = $cfg->getProperties();
    while ((my $key, my $value) = each %{$props})
    {
        print $key, " => ", $value, "\n";
    }
}



#-----------------------------------------------------------------------------
exit(0);
#-----------------------------------------------------------------------------
