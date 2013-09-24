package Dependencies::Searcher;

use 5.010;
use Data::Printer;
use feature qw(say);
# Since 2.99 it got a is_core() method :)
use Module::CoreList 2.99;
use Module::Version 'get_version';
use autodie;
use Moose;
use IPC::Cmd qw[can_run run];
use Dependencies::Searcher::AckRequester;
use Cwd;
use Log::Minimal env_debug => 'LM_DEBUG';
use File::Stamped;
use IO::File;
use File::Temp;

# This module will be used throught a system call
# App::Ack;

our $VERSION = '0.05_06';

=head1 NAME

Dependencies::Searcher - Manage your dependencies list in a convenient way

=cut

=head1 SYNOPSIS

Search recursively dependencies used in a module's directory and build a report that 
can be used as a Carton cpanfile.

    use Dependencies::Searcher;

    my $searcher = Dependencies::Searcher->new();
    my @elements = $searcher->get_files();
    my $path = $searcher->build_full_path(@elements);
    my @uses = $searcher->get_modules($path, "use");
    my @uniq_modules = $searcher->uniq(@uses);

    $searcher->dissociate(@uniq_modules);

    $searcher->generate_report($searcher->non_core_modules);

    # Prints
    # requires Data::Printer, 0.35
    # requires Moose, 2.0602
    # requires IPC::Cmd
    # requires Module::Version

=cut

=head1 DESCRIPTION

Maybe you don't want to have to list all the dependencies of your Perl application by
hand and want an automated way to build it. Maybe you forgot to do it for a long time
ago. During this time, you've add lots of CPAN modules. Carton is here to help you
manage dependencies between your development environment and production, but how to
keep track of the list of modules you will pass to to Carton?

Event if it is a no brainer to keep track of this list, it can be much better not to
have to do it.

You will need a tool that will check for any 'requires' or 'use' in your module package,
and report it into a file that could be used as a Carton cpanfile. Any duplicated entry
will be removed and modules versions will be checked and made available. Core modules
will be ommited because you don't need to install them.

This project has begun because it happens to me, and I don't want to search for modules
to install by hand, I just want to run a simple script that update the list in a simple
way. It was much more longer to write the module than to search by hand but I wish it
will be usefull for others.

=cut

# Init parameters
has 'non_core_modules' => (
    traits     => ['Array'],
    is         => 'rw',
    isa        => 'ArrayRef[Str]',
    default    => sub { [] },
    handles    => {
	add_non_core_module    => 'push',
	count_non_core_modules => 'count',
    },
);

has 'core_modules' => (
    traits     => ['Array'],
    is         => 'rw',
    isa        => 'ArrayRef[Str]',
    default => sub { [] },
    handles    => {
	add_core_module    => 'push',
	count_core_modules => 'count',
    },
);


#  * * * * * * * * * * * * * * *

#      L O G     S T U F F     *

#  * * * * * * * * * * * * * * *

$ENV{LM_DEBUG} = 1;
my $tmp = '/tmp';

my $log_fh = File::Stamped->new(
    pattern => $tmp . "/dependencies-searcher.%Y-%m-%d.out",
);

# Overrides Log::Minimal PRINT
$Log::Minimal::PRINT = sub {
    my ( $time, $type, $message, $trace) = @_;
    print {$log_fh} "$time [$type] $message\n";
};

debugf("Dependencies::Searcher 0.05_03 debugger init.");
debugf("Log file available in /tmp");

#  * * * * * * * * * * * * * * *


sub get_modules {
    my ($self, $pattern, @path) = @_;

    # @path;
    #p $pattern;

    debugf("Coucou");

    my $ack_requester = Dependencies::Searcher::AckRequester->new();

    my @moduls;

    my @params = ('--perl', '-hi', $pattern, @path);

    my $requester = Dependencies::Searcher::AckRequester->new();
    my $ack_path = $requester->get_path();
    my $cmd_use = $requester->build_cmd(@params);
    @moduls = $requester->ack($cmd_use);

    if ( defined $moduls[0]) {
	if ($moduls[0] =~ m/^use/ or $moduls[0] =~ m/^require/) {
	    return @moduls;
	} else {
	    die "Failed to retrieve modules with Ack";
	}
    } else {
	say "No use or require found !";
    }
}

sub get_files {
    my $self = shift;
    # This prefix will allow a more portable module
    my $prefix = getcwd();

    my @structure;
    $structure[0] = "";
    $structure[1] = "";
    $structure[2] = "";
    if (-d $prefix."/lib") {

	$structure[0] = $prefix."/lib";
    } else {
	# 
	# TEST IF THE PATH IS OK ???
	#
	#
	die "Don't look like we are working on a Perl module";
    }

    if (-f $prefix."/Makefile.PL") {
	$structure[1] = $prefix."/Makefile.PL";
    }

    if (-d $prefix."/script") {
	$structure[2] = $prefix."/script";
    }

    return @structure;
}


sub build_full_path {
    my ($self, @elements) = @_;
    my $path = "";
    foreach my $element ( @elements ) {
	$path .= " ./" .  $element;
    }

    # Remove endings " ./"
    $path =~ s/\s\.\/$//;
    return $path;
}

sub merge_dependencies {
    my ($self, @uses, @requires) = @_;
    my @merged_dependencies = (@uses, @requires);
    return @merged_dependencies;
}

# Remove special cases
sub make_it_real {
    my ($self, @merged) = @_;
    my @real_modules;
    foreach my $module ( @merged ) {
	push(@real_modules, $module) unless

	$module =~ m/say/
	# Contains qw()
	or $module =~ m/qw\(\)/
	# Describes a minimal Perl version
	or $module =~ m/^use\s[0-9]\.[0-9]+?/
	or $module =~ m/^use\sautodie?/
	or $module =~ m/^use\sautodie?/;
    }
    return @real_modules;
}


sub clean_everything {
    my @clean_modules = ();
    my ($self, @dirty_modules) = @_;
    foreach my $module ( @dirty_modules ) {

	# remove the 'use' and the space next
	$module =~ s/use\s//i;

	# remove the 'require', quotes and the space next
	# but returns the captured module name (non-greedy)
	$module =~ s/requires\s'(.*?)'/$1/i;
	                                  # i = not case-sensitive
	# Remove the ';' at the end of the line
	$module =~ s/;//i;

	# Remove any qw(xxxx)
	# BUG, should remove spaces
	$module =~ s/\sqw\([A-Za-z]+\)//i;

	# Remove dirty bases and quotes.
	# This regex that substitute My::Module::Name
	# to a "base 'My::Module::Name'" by capturing
	# the name in a non-greedy way
	$module =~ s/base\s'(.*?)'/$1/i;

	# Remove some warning sugar
	$module =~ s/([a-z]+)\sFATAL\s=>\s'all'/$1/i;

	# Remove version numbers
	# http://stackoverflow.com/questions/82064/a-regex-for-version-number-parsing
	$module =~ s/\s(\*|\d+(\.\d+){0,2}(\.\*)?)$//;

	push @clean_modules, $module;
    }
    return @clean_modules;
}


sub uniq {
    my ($self, @many_modules) = @_;
    my @unique_modules = ();
    my %seen = ();
    foreach my $element ( @many_modules ) {
	next if $seen{ $element }++;
	push @unique_modules, $element;
    }
    return @unique_modules;
}


#
# BUG !!! https://github.com/smonff/dependencies-searcher/issues/25
#
# Recent versions of corelist modules are not in corelist but this code portion acts just like it would
#
sub dissociate {
    my ($self, @common_modules) = @_;

    foreach my $nc_module (@common_modules) {

	# my $core_list_answer = `corelist $nc_module`;
	my $core_list_answer = Module::CoreList::is_core($nc_module);

	# debugf("$nc_module version : " .  $Module::CoreList::version{ $] }{"$nc_module"});

	# print "Found " . $nc_module;
	if (
	    (exists $Module::CoreList::version{ $] }{"$nc_module"})
	    or
	    # In case module don't have a version number
	    ($core_list_answer == 1)
	) {
	    # Add to core_module

	    # The old way
	    # You have to push to an array ref (Moose)
	    # http://www.perlmonks.org/?node_id=695034
	    # push @{ $self->core_modules }, $nc_module;

	    # The "Moose" trait way
	    # https://metacpan.org/module/Moose::Meta::Attribute::Native::Trait::Array
	    $self->add_core_module($nc_module);

	} else {
	    $self->add_non_core_module($nc_module);
	    # push @{ $self->non_core_modules }, $nc_module;
	}
    }
}

# Open a file handle to > cpanfile
sub generate_report {

    my $self = shift;

    open my $cpanfile_fh, '>', 'cpanfile';

    foreach my $module_name ( @{$self->non_core_modules} ) {

	my $version = get_version($module_name);
	debugf($module_name);
	debugf $version;

	# if not undef
	if ($version) {
	    # Add the "requires $module_name\n" to the next line of the file
	    chomp($module_name, $version);

	    if ($version =~ m/[0-9]\.[0-9]+/ ) {
		say $cpanfile_fh "requires " . $module_name . ", " . $version;
	    } # else : other case ?

	} else {
	    say $cpanfile_fh "requires " . $module_name;
	}

    }
    close $cpanfile_fh;
}

debugf("-------------  END  -------------");

#sub logm {
    #my $data = shift;

    #open my $log_file, '>>', './t/logs.out';
    #say $log_file }


=head1 SUBROUTINES/METHODS

This is work in progress...

=head2 Dependencies::Searcher->get_modules()

Us-e Ack to get modules and store lines into arrays

=cut

=head2 Dependencies::Searcher->get_files()

TODO

=cut

=head2 Dependencies::Searcher->build_full_path()

Retrieve names of :

=over 2

=item * lib/ directory, if it don't exist, we don't care and die

=item * Makefile.PL

=item * script/ directory, if we use a Catalyst application

=item * ... only if they exists !

=back

=cut

=head2 Dependencies::Searcher->merge_dependencies()

Merge use and requires

=cut

=head2 Dependencies::Searcher->make_it_real()

Remove special cases that can't be interesting.

=cut

=head2 Dependencies::Searcher->clean_everything()

Remove everything but the module name. Remove dirt, clean stuffs...

=cut

=head2 Dependencies::Searcher->uniq()

Make each array element uniq

=cut

=head2 Dependencies::Searcher->dissociate()

Dissociate core / non-core modules

=cut

=head2 Dependencies::Searcher->generate_report()

Generate the cpanfile for Carton, with optionnal version number

=cut

=head2 Log::Minimal::PRINT override

Just override the way Log::Minimal is used. We create a .out file in ./t directory. To see log, use tail -v /path/to/the/module/t/dependencies-searcher.[y-M-d].out

=cut

=head1 AUTHOR

smonff, C<< <smonff at gmail.com> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-dependencies-searcher at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Dependencies-Searcher>.  I will be notified, and then you'll automatically be notified of progress on your bug as I make changes.

=head1 TODOs

https://github.com/smonff/dependencies-searcher/issues

=over 2

=item * Add log into a tmp file and use tail over it to get debug traces during tests and development. Using L<https://metacpan.org/module/Log::Minimal> et L<http://stackoverflow.com/questions/9922899/perl-system-command-redirection-to-log-files>, 

=item * Implement Module::Corelist 2.99 to get is_corelist() method 

=item * Use Module::Version's Perl interface

=item * Bug "outdated" coremodule : if we need a "corelist" module that is a younger release than the one packed in the vanilla system Perl, this is bad...

=back

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Dependencies::Searcher


You can also look for information at:

=over 2

=item * RT: CPAN's request tracker (report bugs here)

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Dependencies-Searcher>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Dependencies-Searcher>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Dependencies-Searcher>

=item * Search CPAN

L<http://search.cpan.org/dist/Dependencies-Searcher/>

=back


=head1 ACKNOWLEDGEMENTS

=over

=item * Brian D. Foy's Module::Extract::Use

Was the main inspiration for this one. First, I want to use it for my needs
but is was not recursive...

See L<https://metacpan.org/module/Module::Extract::Use>

=item * Module::CoreList

What modules shipped with versions of perl. I use it extensively to detect
if the module is from Perl Core or not.

See L<http://perldoc.perl.org/Module/CoreList.html>

=item * Andy Lester's Ack

I've use it as the main source for the module. It was pure Perl so I've choose 
it, even if Ack is not meant for being used programatically, this use do the
job.

See L<http://beyondgrep.com/>

See also :

=over 2

=item * https://metacpan.org/module/Perl::PrereqScanner

=item * http://stackoverflow.com/questions/17771725/

=back

=back

=head1 LICENSE AND COPYRIGHT

Copyright 2013 smonff.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See L<http://dev.perl.org/licenses/> for more information.


=cut

1; # End of Dependencies::Searcher
