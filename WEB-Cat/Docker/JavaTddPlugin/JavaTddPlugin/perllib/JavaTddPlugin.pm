#========================================================================
package JavaTddPlugin;

=head1 NAME

JavaTddPlugin - utility functions used by the JavaTddPlugin

=head1 DESCRIPTION

This module provides some utility functions used by the JavaTddPlugin, but are
not included directly inside the execute.pl script in order to keep it from
getting too large.

=cut

#========================================================================

use Web_CAT::Utilities
    qw(htmlEscape);

#========================================================================
#                      -----  PUBLIC METHODS -----
#========================================================================

#========================================================================
sub transformTestResults
{
=head2 transformTestResults($prefix, $filename, $htmlpath)

Transforms a text file containing JUnit results (written by the basic JUnit
formatter) into an interactive HTML view.

=over

=item $prefix (required)

A prefix attached to DOM identifiers in the generated HTML, which allows
multiple JUnit views to appear on the same page (for example, student tests and
instructor reference tests) without having colliding IDs.

=item $filename (required)

The path to the JUnit result file that is to be parsed.

=item $htmlpath (required)

The path and filename to which the generated HTML will be written.

=back

=cut

    my ($prefix, $filename, $htmlpath) = @_;
    $prefix .= "_";

    my $current_suite;
    my $current_test;
    my @suites;
    my $stats = {
        duration => 0,
        runs => 0,
        errors => 0,
        failed => 0
    };

    my ($firstFailedSuite, $firstFailedTest);

    open TESTRESULTS, $filename or return;

    while (<TESTRESULTS>)
    {
        if ($_ =~ m/Testsuite: (.*)/)
        {
            $current_suite = {
                name => $1,
                duration => 0,
                runs => 0,
                errors => 0,
                failures => 0,
                result => 'success'
            };

            push @suites, $current_suite;
        }
        elsif ($_ =~ m/Testcase: ([^\s]+) took ([0-9.]+) sec/)
        {
            $current_test = {
                name => $1,
                duration => $2,
                result => 'success'
            };

            $current_suite->{'runs'}++;
            $current_suite->{'duration'} += $2;

            $stats->{'runs'}++;
            $stats->{'duration'} += $2;

            push @{$current_suite->{'tests'}}, $current_test;
        }
        elsif ($_ =~ m/(?:Caused an ERROR)|(?:FAILED)/)
        {
            if (!$firstFailedTest)
            {
                $firstFailedSuite = $current_suite->{'name'};
                $firstFailedTest = $current_test->{'name'};
            }

            if ($_ =~ m/Caused an ERROR/)
            {
                $current_test->{'result'} = 'error';
                $current_suite->{'result'} = 'error';

                $current_suite->{'errors'}++;
                $stats->{'errors'}++;
            }
            elsif ($_ =~ m/FAILED/)
            {
                $current_test->{'result'} = 'failed';

                if ($current_suite->{'result'} ne 'error')
                {
                    $current_suite->{'result'} = 'failed';
                }

                $current_suite->{'failed'}++;
                $stats->{'failed'}++;
            }

            my $seenFrame;

            while (<TESTRESULTS>)
            {
                chomp; s/^\s*(.*)\s*$/$1/;
                last if length == 0 && $seenFrame || m/^-+$/;

                if ($current_test->{'reason'} || $_ =~ m/^\s*at/)
                {
                    $seenFrame = 1 if ($_ =~ m/^\s*at/);
                    push @{$current_test->{'trace'}}, $_;
                }
                else
                {
                    $current_test->{'reason'} = $_;
                }
            }
        }
    }

    $stats->{'passes'} = ($stats->{'runs'} - $stats->{'failed'}
        - $stats->{'errors'});
    if ($stats->{'runs'} == 0)
    {
        $stats->{'pass_rate'}    = 0;
        $stats->{'failure_rate'} = 0;
        $stats->{'error_rate'}   = 0;
        $stats->{'all_passed'}   = 0;
    }
    else
    {
        $stats->{'pass_rate'} = 100 * $stats->{'passes'} / $stats->{'runs'};
        $stats->{'failure_rate'} = 100 * $stats->{'failed'} / $stats->{'runs'};
        $stats->{'error_rate'} = 100 * $stats->{'errors'} / $stats->{'runs'};
        $stats->{'all_passed'} =
            ($stats->{'failed'} + $stats->{'errors'} == 0) ? 1 : 0;
    }

    close TESTRESULTS;

    my $resPath = "\${pluginResource:JavaTddPlugin}";

    open HTML, ">$htmlpath";

    print HTML <<EOF ;
<link rel="stylesheet" type="text/css" href="$resPath/junit.css"/>
<script type="text/javascript" src="$resPath/junit.js"></script>
<div class="junit-container">
<div class="junit-stats">
<table>
    <tr>
        <td><img src=\"$resPath/junit-icons/summary-success.gif\"/> Passes: $stats->{'passes'}/$stats->{'runs'}</td>
        <td><img src=\"$resPath/junit-icons/summary-error.gif\"/>  Errors: $stats->{'errors'}/$stats->{'runs'}</td>
        <td><img src=\"$resPath/junit-icons/summary-failed.gif\"/> Failures: $stats->{'failed'}/$stats->{'runs'}</td>
    </tr>
</table>
</div>
<div class="junit-bar">
    <table cellspacing="0" cellpadding="0"><tr>
EOF

    print HTML "<td class=\"junit-bar-fill junit-bar-fill-pass\" style=\"width: "
        . $stats->{'pass_rate'} . "%;\">"
        . int($stats->{'pass_rate'} + 0.5) . "%</td>\n" if $stats->{'pass_rate'};
    print HTML "<td class=\"junit-bar-fill junit-bar-fill-error\" style=\"width: "
        . $stats->{'error_rate'} . "%;\">"
        . int($stats->{'error_rate'} + 0.5) . "%</td>\n" if $stats->{'error_rate'};
    print HTML "<td class=\"junit-bar-fill junit-bar-fill-failure\" style=\"width: "
        . $stats->{'failure_rate'} . "%;\">"
        . int($stats->{'failure_rate'} + 0.5) . "%</td>\n" if $stats->{'failure_rate'};


    print HTML <<EOF ;
    </tr></table>
</div>
<div style="clear: both;"></div>
<div class="junit-tests">
<ul>
EOF

    for my $suite (@suites)
    {
        my $suiteclass = $suite->{'result'};
        my $toggleId = $prefix . "junit_suite_" . $suite->{'name'};
        my $toggleIconId = $toggleId . "_toggler";
        my $testsId = $toggleId . "_tests";
        my $defaultExpansion = ($suite->{'result'} eq 'success') ? 'none' : 'block';
        my $defaultTreeIcon = ($suite->{'result'} eq 'success') ? 'collapsed' : 'expanded';

        print HTML "<li>\n";
        print HTML "<a href=\"javascript:void(0);\" id=\"$toggleId\" onclick=\"junitViewToggleSuite(this.id);\">";
        print HTML "<div id=\"$toggleIconId\" class=\"junit-suite-$defaultTreeIcon\"></div>";
        print HTML "<img src=\"$resPath/junit-icons/suite-$suiteclass.gif\"/>";
        print HTML "<span class=\"junit-title\">$suite->{'name'}</span>";
        print HTML "<span class=\"junit-duration\"> ($suite->{'duration'} s)</span></a>\n";
        print HTML "<ul id=\"$testsId\" style=\"display: $defaultExpansion\">\n";

        for my $test (@{$suite->{'tests'}})
        {
            my $testclass = $test->{'result'};
            my $linkId = $prefix . "junit_test_" . $suite->{'name'} . "_" . $test->{'name'};

            print HTML "<li>";
            print HTML "<a href=\"javascript:void(0);\" id=\"$linkId\" onclick=\"junitViewSetSelectedTrace(this.id);\">";
            print HTML "<img src=\"$resPath/junit-icons/test-$testclass.gif\"/>";
            print HTML "<span class=\"junit-title\">$test->{'name'}</span>";
            print HTML "<span class=\"junit-duration\"> ($test->{'duration'} s)</span></a>\n";
            print HTML "</li>\n";
        }

        print HTML "</ul>\n";
        print HTML "</li>\n";
    }

    print HTML <<EOF ;
</ul>
</div>
<div class="junit-trace">
EOF

    for my $suite (@suites)
    {
        for my $test (@{$suite->{'tests'}})
        {
            if ($test->{'reason'})
            {
                my $blockId = $prefix . "junit_test_" . $suite->{'name'} . "_" . $test->{'name'} . "_block";
                my $reason = htmlEscape($test->{'reason'});

                print HTML "<ul id=\"$blockId\" style=\"display: none\">\n";
                print HTML "<li><img src=\"$resPath/junit-icons/exception.gif\"/>";
                print HTML "<span class=\"junit-title junit-trace-reason\">$reason</span></li>\n";

                for my $trace (@{$test->{'trace'}})
                {
                    print HTML "<li>";

                    if ($trace =~ m/^\s*at/)
                    {
                        print HTML "<img src=\"$resPath/junit-icons/stackframe.gif\"/>";
                    }
                    else
                    {
                        print HTML "&nbsp;&nbsp;&nbsp;&nbsp;";
                    }

                    $trace = htmlEscape($trace);
                    print HTML "<span class=\"junit-title\">$trace</span></li>\n";
                }

                print HTML "</ul>\n";
            }
        }
    }

    print HTML <<EOF ;
</div>
<div style="clear: both;"></div>
</div>
EOF

    if ($firstFailedTest)
    {
        print HTML <<EOF ;
<script type="text/javascript">
junitViewSetSelectedTrace('${prefix}junit_test_${firstFailedSuite}_$firstFailedTest', true);
</script>
EOF
    }

    close HTML;
}

# ---------------------------------------------------------------------------
1;
# ---------------------------------------------------------------------------
__END__

=head1 AUTHOR

Tony Allevato

$Id: JavaTddPlugin.pm,v 1.3 2013/08/11 01:45:05 stedwar2 Exp $
