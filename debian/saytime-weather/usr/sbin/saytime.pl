#!/usr/bin/perl

# saytime.pl - Announces the time and weather information.
# Copyright 2025, Jory A. Pratt, W5GLE
# Based on original work by D. Crompton, WA3DSP
#
# This script retrieves the current time and optionally the weather,
# then generates a concatenated audio file of the time and weather announcement.
# It can either play the audio, or save the sound file.

use strict;
use warnings;
use File::Spec;
use Getopt::Long;
use Log::Log4perl qw(:easy);
use DateTime;
use DateTime::TimeZone;
use Config::Simple;

use constant {
    TMP_DIR => "/tmp",
    BASE_SOUND_DIR => "/usr/share/asterisk/sounds/en",
    WEATHER_SCRIPT => "/usr/sbin/weather.pl",
    DEFAULT_VERBOSE => 0,
    DEFAULT_DRY_RUN => 0,
    DEFAULT_TEST_MODE => 0,
    DEFAULT_WEATHER_ENABLED => 1,
    DEFAULT_24HOUR => 0,
    DEFAULT_GREETING => 1,
    ASTERISK_BIN => "/usr/sbin/asterisk",
    DEFAULT_PLAY_METHOD => 'localplay',
    PLAY_DELAY => 5,
    VERSION => '2.7.5',
};

my %options = (
    location_id => undef,
    node_number => undef,
    silent => 0,
    use_24hour => DEFAULT_24HOUR,
    verbose => DEFAULT_VERBOSE,
    dry_run => DEFAULT_DRY_RUN,
    test_mode => DEFAULT_TEST_MODE,
    weather_enabled => DEFAULT_WEATHER_ENABLED,
    greeting_enabled => DEFAULT_GREETING,
    custom_sound_dir => undef,
    log_file => undef,
    play_method => 'localplay',
);

GetOptions(
    "location_id|l=s" => \$options{location_id},
    "node_number|n=s" => \$options{node_number},
    "silent|s=i" => \$options{silent},
    "use_24hour|h!" => \$options{use_24hour},
    "verbose|v!" => \$options{verbose},
    "dry-run|d!" => \$options{dry_run},
    "test|t!" => \$options{test_mode},
    "weather|w!" => \$options{weather_enabled},
    "greeting|g!" => \$options{greeting_enabled},
    "sound-dir=s" => \$options{custom_sound_dir},
    "log=s" => \$options{log_file},
    "method|m" => sub { $options{play_method} = 'playback' },
) or show_usage();

setup_logging();

my %config;
my $config_file = '/etc/asterisk/local/weather.ini';
if (-f $config_file) {
    Config::Simple->import_from($config_file, \%config)
        or die "Cannot load config file $config_file: " . Config::Simple->error();
} else {
    DEBUG("Creating default configuration file: $config_file") if $options{verbose};
    open my $fh, '>', $config_file
        or die "Cannot create config file $config_file: $!";
    print $fh <<'EOT';
; Weather configuration
[weather]
; Process weather condition announcements (YES/NO)
process_condition = YES

; Temperature display mode (F for Fahrenheit, C for Celsius)
Temperature_mode = F

; Cache settings
cache_enabled = YES
cache_duration = 1800
EOT
    close $fh;
    chmod 0644, $config_file
        or die "Cannot set permissions on $config_file: $!";
}

$config{"weather.Temperature_mode"} ||= "F";
$config{"weather.process_condition"} ||= "YES";

validate_options();

my $critical_error_occurred = 0;

# Process weather FIRST so timezone file is created before getting time
# This ensures time matches the weather location timezone
my $weather_sound_files = process_weather($options{location_id});

# Now get time (will use timezone from weather.pl if available)
my $now = get_current_time($options{location_id});

my $time_sound_files = process_time($now, $options{use_24hour});

my $output_file = File::Spec->catfile(TMP_DIR, "current-time.ulaw");
my $final_sound_files = combine_sound_files($time_sound_files, $weather_sound_files);

if ($options{dry_run}) {
    INFO("Dry run mode - would play: $final_sound_files");
    exit 0;
}

if ($final_sound_files) {
    create_output_file($final_sound_files, $output_file);
}

if ($options{silent} == 0) {
    play_announcement($options{node_number}, $output_file);
    cleanup_files($output_file, $options{weather_enabled}, $options{silent});
} elsif ($options{silent} == 1 || $options{silent} == 2) {
    INFO("Saved sound file to $output_file");
    cleanup_files(undef, $options{weather_enabled}, $options{silent});
}

exit $critical_error_occurred;

sub setup_logging {
    # In non-verbose mode: only show ERROR level with simple format
    # In verbose mode: show everything (DEBUG level) with full format
    my $log_level = $options{verbose} ? $DEBUG : $ERROR;
    my $layout = $options{verbose} ? '%d [%p] %m%n' : '%m%n';
    my %log_params = (
        level  => $log_level,
        layout => $layout
    );
    $log_params{file} = ">>$options{log_file}" if $options{log_file};
    Log::Log4perl->easy_init(\%log_params);
}

sub validate_options {
    if ($options{play_method} !~ /^(localplay|playback)$/) {
        die "Invalid play method: $options{play_method} (must be 'localplay' or 'playback')\n";
    }
    
    show_usage() unless defined $options{node_number} || @ARGV;
    
    $options{node_number} = shift @ARGV if @ARGV && !defined $options{node_number};
    
    die "Node number is required\n" unless defined $options{node_number};
    die "Invalid node number format: $options{node_number}\n" unless $options{node_number} =~ /^\d+$/;
    die "Invalid silent value: $options{silent}\n" if $options{silent} < 0 || $options{silent} > 2;
    
    if ($options{weather_enabled} && !defined $options{location_id}) {
        die "Location ID (postal code) is required when weather is enabled\n";
    }
    
    if ($options{custom_sound_dir}) {
        die "Custom sound directory does not exist: $options{custom_sound_dir}\n" 
            unless -d $options{custom_sound_dir};
    }
}

sub get_current_time {
    my ($location_id) = @_;
    
    # Check if weather.pl saved a timezone file (from Open-Meteo)
    # This makes the time match the weather location
    my $timezone_file = File::Spec->catfile(TMP_DIR, "timezone");
    
    if (defined $location_id && -f $timezone_file) {
        my $timezone;
        if (open my $tz_fh, '<', $timezone_file) {
            chomp($timezone = <$tz_fh>);
            close $tz_fh;
            
            if ($timezone && $timezone ne '') {
                DEBUG("Using timezone from weather location: $timezone") if $options{verbose};
                my $dt = eval {
                    my $dt_obj = DateTime->now;
                    $dt_obj->set_time_zone($timezone);
                    $dt_obj;
                };
                if ($@) {
                    DEBUG("Invalid timezone '$timezone', falling back to local: $@") if $options{verbose};
                } elsif ($dt) {
                    DEBUG("Current time in $timezone: " . $dt->hms) if $options{verbose};
                    return $dt;
                }
            }
        } else {
            DEBUG("Failed to read timezone file: $!") if $options{verbose};
        }
    }
    
    # Fall back to system local time
    DEBUG("Using system local time") if $options{verbose};
    return DateTime->now(time_zone => 'local');
}

# Note: Removed complex timezone and geocoding functions (170+ lines)
# Now using simple system local time - the repeater's timezone is correct for local listeners
# Weather fetching is handled by weather.pl which uses Nominatim + Open-Meteo (no API keys needed)

sub process_time {
    my ($now, $use_24hour) = @_;
    my @files;
    my $sound_dir = $options{custom_sound_dir} || BASE_SOUND_DIR;
    
    if ($options{greeting_enabled}) {
        my $hour = $now->hour;
        my $greeting = $hour < 12 ? "morning" : $hour < 18 ? "afternoon" : "evening";
        push @files, "$sound_dir/rpt/good$greeting.ulaw ";
    }
    
    push @files, "$sound_dir/rpt/thetimeis.ulaw ";
    
    my ($hour, $minute) = ($now->hour, $now->minute);
    
    if ($use_24hour) {
        if ($hour < 10) {
            push @files, "$sound_dir/digits/0.ulaw ";
        }
        push @files, format_number($hour, $sound_dir);
        
        if ($minute == 0) {
            push @files, "$sound_dir/digits/hundred.ulaw ";
            push @files, "$sound_dir/hours.ulaw ";
        } else {
            if ($minute < 10) {
                push @files, "$sound_dir/digits/0.ulaw ";
            }
            push @files, format_number($minute, $sound_dir);
            push @files, "$sound_dir/hours.ulaw ";
        }
    } else {
        my $display_hour = ($hour == 0 || $hour == 12) ? 12 : ($hour > 12 ? $hour - 12 : $hour);
        push @files, "$sound_dir/digits/$display_hour.ulaw ";
        
        if ($minute != 0) {
            if ($minute < 10) {
                push @files, "$sound_dir/digits/0.ulaw ";
            }
            push @files, format_number($minute, $sound_dir);
        }
        push @files, "$sound_dir/digits/" . ($hour < 12 ? "a-m" : "p-m") . ".ulaw ";
    }
    
    return join("", @files);
}

sub process_weather {
    my ($location_id) = @_;
    return "" unless $options{weather_enabled} && defined $location_id;
    
    DEBUG("Fetching weather for location: $location_id") if $options{verbose};

    # Clean up old weather files
    my $temp_file = File::Spec->catfile(TMP_DIR, "temperature");
    my $weather_condition_file = File::Spec->catfile(TMP_DIR, "condition.ulaw");
    unlink $temp_file if -e $temp_file;
    unlink $weather_condition_file if -e $weather_condition_file;
    
    # Run weather script with proper argument escaping
    my $weather_cmd = sprintf("%s %s", WEATHER_SCRIPT, $location_id);
    my $weather_result_raw = system($weather_cmd);
    
    if ($weather_result_raw != 0) {
        my $exit_code = $? >> 8;
        ERROR("Weather script failed:");
        ERROR("  Location: $location_id");
        ERROR("  Command: $weather_cmd");
        ERROR("  Exit code: $exit_code");
        $critical_error_occurred = 1;
        return "";
    }
    
    my $sound_dir = $options{custom_sound_dir} || BASE_SOUND_DIR;
    
    my $files = "";
    if (-f $temp_file) {
        open my $temp_fh, '<', $temp_file or die "Cannot open temperature file: $!";
        chomp(my $temp = <$temp_fh>);
        close $temp_fh;
        
        $files = "$sound_dir/silence/1.ulaw " .
                 "$sound_dir/wx/weather.ulaw " .
                 "$sound_dir/wx/conditions.ulaw $weather_condition_file " .
                 "$sound_dir/wx/temperature.ulaw ";
                 
        if ($temp < 0) {
            $files .= "$sound_dir/digits/minus.ulaw ";
            $temp = abs($temp);
        }
        
        $files .= format_number($temp, $sound_dir);
        $files .= "$sound_dir/wx/degrees.ulaw ";
    } else {
        Log::Log4perl::get_logger()->warn("Temperature file not found after running weather script: $temp_file");
    }
    
    return $files;
}

sub format_number {
    my ($num, $sound_dir) = @_;
    my $files = "";
    my $abs_num = abs($num);

    # Handle zero
    return "$sound_dir/digits/0.ulaw " if $abs_num == 0;

    # Handle hundreds
    if ($abs_num >= 100) {
        my $hundreds = int($abs_num / 100);
        $files .= "$sound_dir/digits/$hundreds.ulaw ";
        $files .= "$sound_dir/digits/hundred.ulaw ";
        $abs_num %= 100;
        return $files if $abs_num == 0;  # Exact hundreds (100, 200, etc.)
    }

    # Handle remaining digits (1-99)
    if ($abs_num < 20) {
        $files .= "$sound_dir/digits/$abs_num.ulaw ";
    } else {
        my $tens = int($abs_num / 10) * 10;
        my $ones = $abs_num % 10;
        $files .= "$sound_dir/digits/$tens.ulaw ";
        $files .= "$sound_dir/digits/$ones.ulaw " if $ones;
    }
    return $files;
}

sub combine_sound_files {
    my ($time_files, $weather_files) = @_;
    my $files = "";
    
    if ($options{silent} == 0 || $options{silent} == 1) {
        $files = "$time_files $weather_files";
    } elsif ($options{silent} == 2) {
        $files = $weather_files;
    }
    
    return $files;
}

sub create_output_file {
    my ($input_files, $output_file) = @_;
    
    # Use Perl's file operations instead of shell command for better security
    open my $out_fh, '>', $output_file
        or die "Cannot open output file $output_file: $!";
    binmode($out_fh);
    
    my @files = split /\s+/, $input_files;
    for my $file (@files) {
        next unless $file && -f $file;
        open my $in_fh, '<', $file
            or do {
                ERROR("Cannot open input file $file: $!");
                $critical_error_occurred = 1;
                next;
            };
        binmode($in_fh);
        my $buffer;
        while (read($in_fh, $buffer, 8192)) {
            print $out_fh $buffer;
        }
        close $in_fh;
    }
    close $out_fh;
}

sub play_announcement {
    my ($node, $asterisk_file) = @_;
    
    $asterisk_file =~ s/\.ulaw$//;

    if ($options{test_mode}) {
        INFO("Test mode - would execute: rpt $options{play_method} $node $asterisk_file");
        return;
    }
    
    my $asterisk_cmd = sprintf(
        "%s -rx \"rpt %s %s %s\"",
        ASTERISK_BIN,
        $options{play_method},
        $node,
        $asterisk_file
    );

    DEBUG("Executing: $asterisk_cmd") if $options{verbose};

    my $asterisk_result_raw = system($asterisk_cmd);
    if ($asterisk_result_raw != 0) {
        my $exit_code = $? >> 8;
        ERROR("Failed to play announcement:");
        ERROR("  Method: $options{play_method}");
        ERROR("  Command: $asterisk_cmd");
        ERROR("  Exit code: $exit_code");
        $critical_error_occurred = 1;
    }
    sleep PLAY_DELAY;
}

sub cleanup_files {
    my ($file_to_delete, $weather_enabled, $silent) = @_;
    
    DEBUG("Cleaning up temporary files:") if $options{verbose};
    
    if (defined $file_to_delete && $silent == 0) {
        DEBUG("  Removing announcement file: $file_to_delete") if $options{verbose};
        unlink $file_to_delete if -e $file_to_delete;
    }
    
    if ($weather_enabled && ($silent == 1 || $silent == 2 || $silent == 0)) {
        my $temp_file = File::Spec->catfile(TMP_DIR, "temperature");
        my $cond_file = File::Spec->catfile(TMP_DIR, "condition.ulaw");
        my $tz_file = File::Spec->catfile(TMP_DIR, "timezone");
        
        DEBUG("  Removing weather files:") if $options{verbose};
        DEBUG("    - $temp_file") if $options{verbose};
        DEBUG("    - $cond_file") if $options{verbose};
        DEBUG("    - $tz_file") if $options{verbose};
        
        unlink $temp_file if -e $temp_file;
        unlink $cond_file if -e $cond_file;
        unlink $tz_file if -e $tz_file;
    }
}

sub show_usage {
    print "saytime.pl version " . VERSION . "\n\n";
    die "Usage: $0 [options] node_number\n" .
    "Options:\n" .
    "  -l, --location_id=ID    Location ID for weather (default: none)\n" .
    "  -n, --node_number=NUM   Node number for announcement (if not provided as argument)\n" .
    "  -s, --silent=NUM        Silent mode (default: 0)\n" .
    "                          0=voice, 1=save time+weather, 2=save weather only\n" .
    "  -h, --use_24hour        Use 24-hour clock (default: off)\n" .    
    "  -v, --verbose           Enable verbose output (default: off)\n" .
    "  -d, --dry-run           Don't actually play or save files (default: off)\n" .
    "  -t, --test              Log playback command instead of executing (default: off)\n" .
    "  -w, --weather           Enable weather announcements (default: on)\n" .
    "  -g, --greeting          Enable greeting messages (default: on)\n" .
    "  -m                      Enable playback mode (default: localplay)\n" .
    "      --sound-dir=DIR     Use custom sound directory\n" .
    "                          (default: /usr/share/asterisk/sounds/en)\n" .
    "      --log=FILE          Log to specified file (default: none)\n" .
    "      --help              Show this help message and exit\n\n" .
    "Location ID: Any postal code worldwide\n" .
    "  - US: 77511, 10001, 90210\n" .
    "  - International: 75001 (Paris), SW1A1AA (London), etc.\n" .
    "Examples:\n" .
    "  perl saytime.pl -l 77511 -n 546054\n" .
    "  perl saytime.pl -l 77511 546054 -s 1\n" .
    "  perl saytime.pl -l 77511 546054 -h\n\n" .
    "Configuration in /etc/asterisk/local/weather.ini:\n" .
    "  - Temperature_mode: F/C (default: F)\n" .
    "  - process_condition: YES/NO (default: YES)\n\n" .
    "Note: No API keys required! Uses system time and weather.pl for weather.\n";
}