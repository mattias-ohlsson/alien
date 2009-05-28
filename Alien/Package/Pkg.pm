#!/usr/bin/perl -w

=head1 NAME

Alien::Package::Pkg - an object that represents a Solaris pkg package

=cut

package Alien::Package::Pkg;
use strict;
use base qw(Alien::Package);

=head1 DESCRIPTION

This is an object class that represents a pkg package, as used in Solaris. 
It is derived from Alien::Package.

=head1 CLASS DATA

=over 4

=item scripttrans

Translation table between canoical script names and the names used in
pkg's.

=cut

use constant scripttrans => {
	postinst => 'postinstall',
	postrm => 'postremove',
	prerm => 'preremove',
	preinst => 'preinstall',
};

my %REQUEST_ENV = ();

=back

=head1 METHODS

=over 4

=item init

This class needs the Solaris pkginfo and kgtrans tools to work.

=cut

sub init {
	foreach (qw(/usr/bin/pkginfo /usr/bin/pkgtrans)) {
		-x || die "$_ is needed to use ".__PACKAGE__."\n";
	}
}

=item converted_name

Convert name from something debian-like to something that the
Solaris constraints will handle (i.e. 9 chars max).

=cut

sub converted_name {
	my $this = shift;
	my $prefix = "ALN";
	my $name = $this->name;

	for ($name) {		# A Short list to start us off.
				# Still, this is risky since we need
				# unique names.
		s/^lib/l/;
		s/-perl$/p/;
		s/^perl-/pl/;
	}
	
	$name = substr($name, 0, 9);

	return $prefix.$name;
}

=item checkfile

Detect pkg files by their contents.

=cut

sub checkfile {
	my $this=shift;
	my $file=shift;

	if (-d $file) {
		return 1 if (-f "$file/pkginfo");
		for my $d (glob("$file/*")) {
			return 1 if (-f "$d/pkginfo");
		}
		return 0;
	}

	open(F, $file) || die "Couldn't open $file: $!\n";
	my $line = <F>;
	close F;

	return unless defined $line;
	
	if($line =~ "# PaCkAgE DaTaStReAm") {
		return 1;
	}
}

=item install

Install a pkg with pkgadd. Pass in the filename of the pkg to install.

=cut

sub install {
	my $this=shift;
	my $pkg=shift;

	if (-x "/usr/sbin/pkgadd") {
		$this->do("/usr/sbin/pkgadd", "-d .", "$pkg")
			or die "Unable to install";
	}
	else {
		die "Sorry, I cannot install the generated .pkg file ".
			"because /usr/sbin/pkgadd is not present.\n";
	}
}

=item scan

Scan a pkg file for fields.

=cut

sub scan {
	my $this=shift;
	$this->SUPER::scan(@_);
	my $file=$this->filename;
	my $tdir="pkg-scan-tmp.$$";
	my $tdir_saved=$tdir;

	my $pkgname;
	my $pkginfo;

	die "Couldn't find pkginfo: $!\n"
		if (! -x "/usr/bin/pkginfo");

	if (-f "$file/pkginfo") {
		open(INFO, "$file/pkginfo")
			|| die "Couldn't open '$file/pkginfo': $!\n";
		my ($key, $value);
		while (<INFO>) {
			if (/(.*?)=(.*)/) {
				$key = $1;
				$value = $2;
				next if ($key ne 'PKG');
				$pkgname = $value;
				last;
			}
		}
		close INFO;
	} else {
		open(INFO, "/usr/bin/pkginfo -d $file|")
			|| die "Couldn't open pkginfo: $!\n";
		$_ = <INFO>;
		($pkgname) = /\S+\s+(\S+)/;
		close INFO;
	}

	if (! -d $file) {
		die "Couldn't find pkgtrans: $!\n"
			if (! -x "/usr/bin/pkgtrans");

		$this->do("mkdir", $tdir) || die "Error making $tdir: $!\n"; 

		# Extract the files
		$this->do("/usr/bin/pkgtrans $file $tdir $pkgname >/dev/null 2>&1")
			|| die "Error running pkgtrans: $!\n";
		$tdir = "$tdir/$pkgname";
	} elsif (-f "$file/pkginfo") {
		$tdir = $file;
	} else {
		$tdir = "$file/$pkgname";
	}

	# debug...
	# print "DEBUG: Saving original copy at /tmp/$pkgname...\n";
	# system("rm -rf /tmp/$pkgname; cp -ar $tdir /tmp");

	open(INFO, "$tdir/pkginfo")
		|| die "Couldn't open '$tdir/pkginfo': $!\n";
	my ($key, $value);
	while (<INFO>) {
		if (/(.*?)=(.*)/) {
			$key = $1;
			$value = $2;
		} else {
			$value = $_;
		}
		if ($key =~ /ARCH/) {
			if (($value =~ /sparc/ && $value =~ /.86/) ||
			     $value =~ /all/) {
				$value = "all";
			} elsif ($value =~ /.86/) {
				$value = "solaris-i386";
			} else {
				$value = "solaris-sparc";
			}
		}
		push @{$pkginfo->{$key}}, $value;
	}
	close INFO;
	$file =~ m,([^/]+)-[^-]+(?:.pkg)$,;
	$this->name(lc($pkgname));
	$this->arch($pkginfo->{ARCH}->[0]);
	$this->summary($pkginfo->{NAME}->[0]);
	$this->description(join("", @{[$pkginfo->{DESC}->[0] || "."]}));
	# Make sure we place files in the right places relative to the original package
	if (exists $pkginfo->{BASEDIR} && $pkginfo->{BASEDIR}->[0] ne '/') {
		# warn( 'Detected non root base dir in package: ' . $pkginfo->{BASEDIR}->[0] );
		$this->{basedir} = $pkginfo->{BASEDIR}->[0];
	} else {
		$this->{basedir} = '/';
	}
	# Decode SUNW_PRODVERS first then VERSION
	if (exists $pkginfo->{SUNW_PRODVERS} && $pkginfo->{SUNW_PRODVERS}->[0] ne '') {
		#
		# example: 5.11/snv_17
		# want: 5.11
		$this->version($1) if ($pkginfo->{SUNW_PRODVERS}->[0] =~ /([0-9\.]+)\/.*/);
		$this->version($1) if (!defined $this->version() &&
				       exists $pkginfo->{SUNW_PKGVERS} &&
				       $pkginfo->{SUNW_PKGVERS}->[0] ne '' &&
				       $pkginfo->{SUNW_PKGVERS}->[0] =~ /([0-9\.]+)/);
	}
	
	if (!defined $this->version()) {
		#
		# example: 11.11,REV=2005.07.12.10.17
		# want: version=11.11-rev2005.07.12.10.17
		# NB: release should not = 2005.07.12.10.17 because it gets chopped up
		if ($pkginfo->{VERSION}->[0] =~ /([0-9\.]+)\s*,\s*[Rr][Ee][Vv]\s*=([0-9\.]*)\s*.*/) {
			my $tmp_v = $1;
			$tmp_v .= "-rev$2" if $2 ne '';
			$this->version($tmp_v);
		#
		# example: VERSION=Solaris, Rev=5.01
		# want: 5.01
		} elsif ($pkginfo->{VERSION}->[0] =~ /.*\s*,\s*[Rr][Ee][Vv]\s*=\s*([0-9\.]+)/) {
			$this->version($1);
		#
		# example: VERSION=5.0.1a
		# want: 5.0.1a
		} elsif ($pkginfo->{VERSION}->[0] =~ /^([0-9a-zA-Z\.]+)$/) {
			$this->version($1);
		#
		# sucky case... setup hard-coded version to be 1.0
		} else {
			print "Warning: unable to parse version from input '$pkginfo->{VERSION}->[0]'\n";
			$this->version('1.0');
		}
	}
	$this->distribution("Nexenta");
	$this->group($pkginfo->{CATEGORY}->[0]);
	$this->origformat('pkg');
	$this->changelogtext('');
	$this->binary_info('unknown'); # *** FIXME

	# install/depend example:
	#
	# You can define three types of pkg dependencies with this file:
	#	 P indicates a prerequisite for installation
	#	 I indicates an incompatible package
	#	 R indicates a reverse dependency
	# <pkg.abbr> see pkginfo(4), PKG parameter
	# <name> see pkginfo(4), NAME parameter
	# <version> see pkginfo(4), SUNW_PRODVERS/VERSION parameter
	# <arch> see pkginfo(4), ARCH parameter
	# <type> <pkg.abbr> <name>
	# 	(<arch>)<version>
	# 	(<arch>)<version>
	# 	...
	# <type> <pkg.abbr> <name>
	# ...
	#
	# P SUNWcar	Core Architecture, (Root)
	# P SUNWcakr	Core Solaris Kernel Architecture (Root)
	# P SUNWkvm	Core Architecture, (Kvm)
	# P SUNWcsr	Core Solaris, (Root)
	# P SUNWckr	Core Solaris Kernel (Root)
	# P SUNWcnetr	Core Solaris Network Infrastructure (Root)
	# P SUNWcsu	Core Solaris, (Usr)
	# P SUNWcsd	Core Solaris Devices
	# P SUNWcsl	Core Solaris Libraries

	if (-f "$tdir/install/depend") {
		my $data = '';
		open (DEPENDS, "$tdir/install/depend")
			|| die "Couldn't open install/depend: $!\n";
		while (<DEPENDS>) {
			# skip obsolete packages
			if (m,^P\s+(\S+)\s+(.*),) {
				next if ($1 eq "SUNWcar");
				$data .= ", " if ($data ne '');
				$data .= lc($1);
			}
		}
		$this->depends($data);
		print "\tdepends: $data\n"
			if ($Alien::Package::verbose);
		close(DEPENDS);
	}

	if (-f "$tdir/install/copyright") {
		open (COPYRIGHT, "$tdir/install/copyright")
			|| die "Couldn't open install/copyright: $!\n";
		$this->copyright(join("",<COPYRIGHT>));
		close(COPYRIGHT);
	}
	else {
		$this->copyright("unknown");
	}

	# Now figure out the conffiles. Assume anything in etc/ is a
	# conffile.
	my @conffiles;
	my @filelist;
	my @scripts;
	open (FILELIST,"$tdir/pkgmap") ||
		die "getting filelist ($tdir/pkgmap): $!";
	while (<FILELIST>) {
		if (m,^1\s+f\s+\S+\s+etc/([^\s=]+),) {
			push @conffiles, "/etc/$1";
		}
		# [fd] example:
		#
		# 1 d none kernel/drv 0755 root sys
		# 1 f none kernel/drv/xge 0755 root sys 365728 9228 1121127995
		if (m,^1\s+[fd]\s+\S+ ([^\s=]+),) {
			push @filelist, $1;
		}
		if (m,^1\s+i\s+(\S+),) {
			push @scripts, $1 if (-f "$tdir/install/$1");
		}
		push @scripts, "i.none" if (-f "$tdir/install/i.none");
		push @scripts, "r.none" if (-f "$tdir/install/r.none");
	}
	$this->postinst(' ') if (grep { /^i\./ } @scripts);
	$this->prerm(' ') if (grep { /^r\./ } @scripts);

	$this->filelist(\@filelist);
	$this->conffiles(\@conffiles);

	# Handle SVR4 request script if any...
	# this guy may modify executable environment.
	if (-f "$tdir/install/request" && scalar keys %REQUEST_ENV == 0) {
		print "$pkgname: executing SVR4 request script ...\n";
		my $rc = system ("PATH=/usr/sun/bin:/bin:/usr/sbin:\$PATH ".
			"ARCH=i386 ".
			"PKGINST=".lc($pkgname)." ".
			"PKGSAV=/tmp/$pkgname.$$.1 ".
			"PKG=".lc($pkgname)." ".
			"EXT= ".
			"BASEDIR=" . $this->{basedir} . " ".
			"INST_DATADIR=/tmp/$pkgname.$$.2 ".
			"SUN_PERSONALITY=1 ".
			"/sbin/sh $tdir/install/request /tmp/$pkgname.$$");
		die "Couldn't complete SVR4 request script session"
			if ($rc != 0);
		if (open FD, "/tmp/$pkgname.$$") {
			my ($key, $value);
			while (<FD>) {
				if (/(.*?)=(.*)/) {
					$key = $1;
					$value = $2;
					$REQUEST_ENV{$key}=$value;
				}
			}
			close FD;
		}
		system("rm -rf /tmp/$pkgname.$$*");
	}

	# Now get the scripts.
	foreach my $script (keys %{scripttrans()}) {
		if (-e "$tdir/install/".scripttrans()->{$script}) {
			my $data;
			$data=$this->runpipe(0, "cat $tdir/install/".scripttrans()->{$script});
			$data='' if $data eq '(none)';
			$this->$script($data);
		}
	}

	$this->do("rm -rf $tdir_saved") if (! -d $file);

	return 1;
}

=item unpack

Unpack pkg and prepare reloc based on pkgmap.

=cut

sub unpack {
	my $this=shift;
	$this->SUPER::unpack(@_);
	my $file=$this->filename;
	my @alldirs = ();

	# the location of special SVR4 classes (awk, sed, build, etc...)
	my $sadmdir = "/usr/sadm/install/scripts";
	my $csrdir = "/var/lib/dpkg/alien/sunwcsr";

	my $workdir = $this->name."-".$this->version;
	my $basedir = $this->{basedir};

	my $pkgname;

	if (-f "$file/pkginfo") {
		open(INFO, "$file/pkginfo")
			|| die "Couldn't open '$file/pkginfo': $!\n";
		my ($key, $value);
		while (<INFO>) {
			if (/(.*?)=(.*)/) {
				$key = $1;
				$value = $2;
				next if ($key ne 'PKG');
				$pkgname = $value;
				last;
			}
		}
		close INFO;
	} else {
		open(INFO, "/usr/bin/pkginfo -d $file|")
			|| die "Couldn't open pkginfo: $!\n";
		$_ = <INFO>;
		($pkgname) = /\S+\s+(\S+)/;
		close INFO;
	}

	if (! -d $file) {

		die "Couldn't find pkgtrans: $!\n"
			if (! -x "/usr/bin/pkgtrans");

		if (! -e $workdir) {
			$this->do("mkdir", $workdir) || die "Error making $workdir: $!\n"; 
		}

		# Extract the files
		$this->do("/usr/bin/pkgtrans $file $workdir $pkgname >/dev/null 2>&1")
			|| die "unable to extract $file: $!\n";

		rename("$workdir/$pkgname", "${workdir}_1")
			|| die "unable rename $workdir/$pkgname: $!\n";
		rmdir $workdir;
		rename("${workdir}_1", $workdir)
			|| die "unable to rename ${workdir}_1: $!\n";
	} else {
		rmdir $workdir if (-e $workdir);
		if (-f "$file/pkginfo") {
			system("cp -ar $file $workdir");
		} elsif (-f "$file/$pkgname/pkginfo") {
			system("cp -ar $file/$pkgname $workdir");
		} else {
			die "bad package layout\n";
		}
	}
	$this->unpacked_tree($workdir);

	# Relocate pkgmap if needed
	if (scalar keys %REQUEST_ENV > 0) {
		open (FILELIST,"$workdir/pkgmap") || die "getting filelist ($workdir/pkgmap): $!";
		open (FILELIST_OUT,">$workdir/pkgmap.$$") || die "could not open filelist ($workdir/pkgmap.$$): $!";
		while (<FILELIST>) {
			my $line = $_;
			for my $k (keys %REQUEST_ENV) {
				my $value = $REQUEST_ENV{$k};
			       	$value =~ s/[\'\"]//g;
				$line =~ s/(.*)\$$k(.*)/$1$value$2/g;
			}
			print FILELIST_OUT $line
		}
		close FILELIST;
		close FILELIST_OUT;
		system("mv $workdir/pkgmap.$$ $workdir/pkgmap");
	}

	# Test to see if the package contains the relocation directory
	if (-d "$workdir/reloc") {
		# Get the files to move.
		my @filelist=glob("$workdir/reloc/*");

		# Now, make the destination directories, do relocations.
		foreach my $f (@{filelist}) {
			my $loc = "$workdir/";
			if (basename($f) =~ /\$(.*)/) {
				my $test_key = $1;
				if (exists $REQUEST_ENV{$test_key}) {
					my $rdir = $REQUEST_ENV{$test_key};
				       	$rdir =~ s/[\'\"]//g;
				       	$rdir =~ s/\/$//;
					if (! -d "$workdir/$rdir") {
						$loc = "$workdir/$rdir";
						my $new_topdir = $rdir;
					        $new_topdir =~ s/^\///;
						$new_topdir = $1 if ($new_topdir =~ /(.*?)\/.*/);
						push @alldirs, $new_topdir;
						system("mkdir -p ".dirname($loc));
					}
				} else {
					print "Warning: unable to relocate '".basename($f)."'\n";
				}
			}
			$this->do("mv", $f, $loc) ||
				die "error moving unpacked reloc files into the default directory: $!";
		}
		rmdir "$workdir/reloc";
	}

	# Test to see if the package contains the 'root' directory
	if (-d "$workdir/root") {
		# Get the files to move.
		my @filelist=glob("$workdir/root/*");

		# Now, merge / to the destination directory.
		foreach my $f (@{filelist}) {
			my $dest = "$workdir/".basename($f,"");
			$this->do("mkdir $dest") if (! -d "$dest");
			$this->do("cp -ar $f/* $dest") ||
				die "error moving unpacked root files into the default directory: $!";
		}
		system("rm -rf $workdir/root");
	}

	# Change relocation position to root if specified
	my $alienloc = (defined $Alien::Package::reloc_root) ?
		"$workdir/" . $Alien::Package::reloc_root :
		"$workdir/var/lib/dpkg/alien/".lc($this->name);
	$alienloc =~ s/\/+/\//g;
	print "Reloc Root: $alienloc\n" if ($Alien::Package::verbose);
	if (! -d "$alienloc") {
		$this->do("mkdir", "-p", "$alienloc/reloc") || die "unable to mkdir $alienloc/reloc: $!";
	}
	if (! defined($Alien::Package::reloc_root) || $Alien::Package::reloc_root ne '/') {
		$this->do("cp", "$workdir/pkgmap", "$alienloc/") || die "error moving pkgmap: $!";
	}

	# Set final Alien destination for reloc'd files
	$alienloc = ($Alien::Package::reloc_root) ?
		"/" . $Alien::Package::reloc_root :
		"/var/lib/dpkg/alien/".lc($this->name);
	$alienloc =~ s/\/+/\//g;
	print "Reloc Root: $alienloc" if ($Alien::Package::verbose);

	my $begin = "\n# generated by alien\n".
		"PATH=/usr/sun/bin:/bin:/usr/sbin:\$PATH\n".
		"ARCH=i386\n".
		"PKGINST=".lc($this->name)."\n".
		"PKGSAV=$alienloc\n".
		"PKG=".lc($this->name)."\n".
		"EXT=\n".
		"BASEDIR=/etc/../; export BASEDIR\n".
		"PKG_INSTALL_ROOT=/etc/../; export PKG_INSTALL_ROOT\n".
		"INST_DATADIR=/var/lib/dpkg/alien; export INST_DATADIR\n".
		"SUN_PERSONALITY=1; export SUN_PERSONALITY\n".
		'cat /var/lib/dpkg/status | grep "^Package:\s* '.lc($this->name).'" >/dev/null && UPDATE=yes'."\n";
	for my $req_key (keys %REQUEST_ENV) {
		$begin .= "$req_key=$REQUEST_ENV{$req_key}\n";
	}
	my $alien_funcs='
installf() {
	_op=$1; _class=$2; _pkginst=$3; _path=$4; _type=$5; _major=$6; _minor=$7
	_mode=$8; _owner=$9; shift; _group=$9
	if test "x$_op" = "x-f"; then
		_pkginst=$_class
		_pipefile=/tmp/$_pkginst.installf
		echo "Applying $_pkginst.installf"
		test -f $_pipefile && . $_pipefile
		rm -f $_pipefile
		return 0
	else
		_pipefile=/tmp/$_pkginst.installf
	fi
	if test "x$_op" != "x-c"; then
		echo "unsupported operation: $_op"; return 1
	fi
	if test "x$_path" = "x-"; then
		read _dstsrc _type
		_dst=`echo $_dstsrc | cut -d= -f1`
		_src=`echo $_dstsrc | cut -d= -f2`
		test "x$_type" = "xs" && _type="-s"
		test "x$_type" = "xl" && _type=""
		if test "x$_type" = "xs" -a "x$_type" != "xl"; then
			echo "unsupported type: $_type"; return 1
		fi
		test x$_dst = x -o x$_src = x && return 1
		echo "rm -f $_dst; ln $_type $_src $_dst" >> $_pipefile
		return 0
	fi
	echo "rm -f $_path; mknod $_path $_type $_major $_minor; chown $_owner $_path; chgrp $_group $_path; chmod $_mode $_path" >> $_pipefile
	return 0
}
removef() {
	_op=$1; _pkginst=$2; _path=$3
	test "x$_op" = "x-f" && return 0
	echo $_path
	return 0
}
';
	my $content;
	my $install_action = '';
	my $remove_action = '';
	open (FILELIST,"$workdir/pkgmap") || die "getting filelist ($workdir/pkgmap): $!";
	while (<FILELIST>) {

		# handle links
		if (m,^1\s+([ls])\s+none\s+([^\s=]+)=([^\s=]+),) {
			my ($type, $dest, $src) = ($1, $2, $3);
			my $flag = "";
			$flag = "-s" if $type eq "s";
			use File::Basename;
			my $curdir = $ENV{'PWD'};
			my $cmd .= "cd $workdir".dirname("/$dest").";".
			     "ln $flag $src ".basename("/$dest", "");
			system($cmd);
			chdir($curdir);
		}

		# handle the rest
		if (m,^1\s+([vxefd])\s+(\S+)\s+([^\s=]+)\s+(\S+)\s+(\S+)\s+(\S+) *,) {

			my ($t, $class, $fn, $mode, $owner, $group) = ($1, $2, $3, $4, $5, $6);

			if ($fn =~ /^\//) {
				$fn =~ s/^\///;
			}
			push @alldirs, $fn if ($t eq "d");

			if ($t eq "d" && ! -d "$workdir/$fn") {
				$this->do("mkdir", "-p", "$workdir/$fn") ||
				      die "unable to mkdir $workdir/$fn: $!";
			}

			my $has_class = 0;
			my $ctype_i = "";
			my $ctype_r = "";
			my %classloc = ();
			if ($t ne "d") {
				if (-f "$workdir/install/i.$class") {
					$ctype_i = "i";
					$classloc{i} = "$workdir/install/i.$class";
				} elsif (-f "$sadmdir/i.$class") {
					$ctype_i = "i";
					$classloc{i} = "$sadmdir/i.$class";
				} elsif (-f "$csrdir/i.$class") {
					$ctype_i = "i";
					$classloc{i} = "$csrdir/i.$class";
				}
				if (-f "$workdir/install/r.$class") {
					$ctype_r = "r";
					$classloc{r} = "$workdir/install/r.$class";
				} elsif (-f "$sadmdir/r.$class") {
					$ctype_r = "r";
					$classloc{r} = "$sadmdir/r.$class";
				} elsif (-f "$csrdir/r.$class") {
					$ctype_r = "r";
					$classloc{r} = "$csrdir/r.$class";
				}

				die "no class '$class' found!"
					if ($ctype_i eq "" && $ctype_r eq "" && $class ne "none" && $class ne "conf" && $class ne "init");

				if (($class eq "conf" || $class eq "none" || $class eq "init") && $ctype_i eq "" && $ctype_r eq "") {
					$has_class = 0
				} else {
					$has_class = 1
				}
			}

			if ($has_class) {
				foreach my $ctype ($ctype_i, $ctype_r) {
				next if ($ctype eq "");

				my $alienname="$ctype.$class";
				my $bfn=basename("/$fn", "");

				if ($this->usescripts &&
				    ! -f "$workdir$alienloc/$alienname") {

					# move class scripts to $workdir/$alienloc
					# and prepare its executional environment

					system("echo '#!/sbin/sh\n".$begin.$alien_funcs.
					       "\n# end of alien\n\n' > /tmp/alien;".
					       "cat $classloc{$ctype} >> /tmp/alien");

					$this->do("cp", "/tmp/alien", "$workdir$alienloc/$alienname") ||
						die "failed to copy class $class: $!";
					$this->do("chmod", "755", "$workdir$alienloc/$alienname") ||
						die "failed changing mode of $workdir$alienloc/$alienname to 755\: $!";
					system("rm -f /tmp/alien");

				}

				my $pipe_setup_cmd = "echo \$INST_DATADIR/\$PKG/reloc/$fn /$fn | ";
				$pipe_setup_cmd = "echo \$INST_DATADIR/\$PKG/reloc/ $fn | awk '{print \$1\"\\n\"\$2}' | "
					if (! -e "$workdir/$fn");

				$install_action .=
					"echo Setting up class: $class /$fn\n$pipe_setup_cmd".
					"\$INST_DATADIR/\$PKG/$alienname $t $class $fn $mode $owner $group\n"
						if ($ctype eq "i");

				$remove_action .=
					"echo Cleaning up class: $class /$fn\n".
					"echo /$fn | \$INST_DATADIR/\$PKG/$alienname $t $class $fn $mode $owner $group\n"
						if ($ctype eq "r");
				}

				# move file proccessed by classes to reloc
				if (-e "$workdir/$fn") {
					my $reloc_fn = "$workdir/$alienloc/reloc/$fn";
					$this->do("mkdir -p ".dirname($reloc_fn));
					$this->do("mv", "$workdir/$fn", dirname($reloc_fn));
					$fn = $reloc_fn;
				}
			}
			my $uid = getpwnam($owner);
			$uid=0 if (!defined $uid);
			
			my $gid = getgrnam($group);
			$gid=0 if (!defined $gid);

			# skip broken links
			next unless -e "$workdir/$fn";
			if ($> == 0) {
				$this->do("chown", "$uid:$gid", "$workdir/$fn") ||
					die "failed chowning $fn to $uid\:$gid\: $!";
			}
			next if -l "$workdir/$fn"; # skip links

			if ($mode ne '?') {
				$this->do("chmod", $mode, "$workdir/$fn") ||
					die "failed changing mode of $fn to $mode\: $!";
			}
		}
	}
	close (FILELIST);

	my $comment = $begin.$alien_funcs.
		"\nalien_atexit() {\n";
	if ($install_action ne '') {
		my $endcomment = "\n}\ntrap alien_atexit EXIT\n# end of alien\n\n";
		$content = $this->postinst();
		if (defined $this->postinst && $content ne '') {
			$content =
				"#!/sbin/sh\n".$comment.$install_action.
				$endcomment.$content;
		} else {
			$content = "#!/sbin/sh\n".$comment.$install_action.
				$endcomment;
		}
		$this->postinst($content);
	} else {
		$content = $this->postinst();
		if (defined $this->postinst && $content ne '') {
			$content = "#!/sbin/sh\n".$begin.$alien_funcs.$content;
			$this->postinst($content);
		}
	}
	if ($remove_action ne '') {
		my $endcomment = "\n}\ntest x\$1 != xupgrade && alien_atexit; true\n# end of alien\n\n";
		$content = $this->prerm();
		if (defined $this->prerm && $content ne '') {
			$content =
				"#!/sbin/sh\n".$comment.$remove_action.
				$endcomment.$content;
		} else {
			$content = "#!/sbin/sh\n".$comment.$remove_action.
				$endcomment;
		}
		$this->prerm($content);
	} else {
		$content = $this->prerm();
		if (defined $this->prerm && $content ne '') {
			$content = "#!/sbin/sh\n".$begin.$alien_funcs.$content;
			$this->prerm($content);
		}
	}
	$content = $this->postrm();
	if (defined $this->postrm && $content ne '' && $this->usescripts) {
		$content = "#!/sbin/sh\n".$begin.$alien_funcs.$content;
		$this->postrm($content);
	}
	$content = $this->preinst();
	if (defined $this->preinst && $content ne '' && $this->usescripts) {
		$content = "#!/sbin/sh\n".$begin.$alien_funcs.$content;
		$this->preinst($content);
	}

	# since we've parsed all we need at scan() time, remove it
	$this->do("rm -f $workdir/pkgmap");
	$this->do("rm -f $workdir/pkginfo");
	$this->do("rm -rf $workdir/install");

	# Do actual relocation in package
	if (! defined($Alien::Package::reloc_root) || $Alien::Package::reloc_root ne '/') {
		push @alldirs, ("debian","var");
		for my $d (glob("$workdir/*")) {
			next if $d =~ /reloc\/*$/;
			$d =~ s/.*?\/(.*)/$1/;
			if (! scalar grep { /^$d$/ } @alldirs) {
				if (! -d "$workdir/$alienloc/reloc/$d") {
					$this->do("mv $workdir/$d $workdir/$alienloc/reloc/");
					print "Relocate $workdir/$d -> $workdir/$alienloc/reloc/\n"
						if ($Alien::Package::verbose);
				}
			}
		}
	}

	# Finally, relocate all packages underneath the install base
	if( $basedir ne '/' ) {
		if(! -d "$workdir/$basedir" ) {
			$this->do("mkdir", "-p", "$workdir/$basedir") ||
				die("While creating $workdir/$basedir: " . $!);
		}
		my $base_basedir = $basedir;
		$base_basedir =~ s#/*(\w+)/.*#$1#; # Base of directory structure
		for my $d (glob("$workdir/*")) {
			next if $d =~ /$base_basedir/; # Don't move basedir somewhere else
			next if $d =~ /usr\/share/; # Don't move documentation
			next if $d =~ /var\/.*dpkg/; # Don't mess with dpkg
			# Don't mess with random aliens from mars or pluto
			# which happens to not be a planet anymore
			next if $d =~ /var\/.*alien/;
			$this->do("mv $d $workdir/$basedir/");
		}
	}

}

=item prep

Adds a populated install directory to the build tree.

=cut

sub prep {
	my $this=shift;
	my $dir=$this->unpacked_tree ||
		die "The package must be unpacked first!";

#  	opendir(DIR, $this->unpacked_tree);
#  	my @sub = map {$this->unpacked_tree . "$_"}
#  	  grep {/^\./} readdir DIR;
#  	closedir DIR;

	$this->do("cd $dir; find . -print | pkgproto > ./prototype")
		|| die "error during pkgproto: $!\n";

	open(PKGPROTO, ">>$dir/prototype")
		|| die "error appending to prototype: $!\n";

	open(PKGINFO, ">$dir/pkginfo")
		|| die "error creating pkginfo: $!\n";
	print PKGINFO qq{PKG="}.$this->converted_name.qq{"\n};
	print PKGINFO qq{NAME="}.$this->name.qq{"\n};
	print PKGINFO qq{ARCH=i386\n};
	print PKGINFO qq{VERSION="}.$this->version.qq{"\n};
	print PKGINFO qq{CATEGORY="application"\n};
	print PKGINFO qq{VENDOR="Alien-converted package"\n};
	print PKGINFO qq{EMAIL=\n};
	print PKGINFO qq{PSTAMP=alien\n};
	print PKGINFO qq{MAXINST=1000\n};
	print PKGINFO qq{BASEDIR="/"\n};
	print PKGINFO qq{CLASSES="none"\n};
	print PKGINFO qq{DESC="}.$this->description.qq{"\n};
	close PKGINFO;
	print PKGPROTO "i pkginfo=./pkginfo\n";

	$this->do("mkdir", "$dir/install") ||
		die "unable to mkdir $dir/install: $!";
	open(COPYRIGHT, ">$dir/install/copyright")
		|| die "error creating copyright: $!\n";
	print COPYRIGHT $this->copyright;
	close COPYRIGHT;
	print PKGPROTO "i copyright=./install/copyright\n";

	foreach my $script (keys %{scripttrans()}) {
		my $data=$this->$script();
		my $out=$this->unpacked_tree."/install/".
			${scripttrans()}{$script};
		next if ! defined $data || $data =~ m/^\s*$/;

		open (OUT, ">$out") || die "$out: $!";
		print OUT $data;
		close OUT;
		$this->do("chmod", 755, $out);
		print PKGPROTO "i $script=$out\n";
	}
	close PKGPROTO;
}

=item build

Build a pkg.

=cut

sub build {
	my $this = shift;
	my $dir = $this->unpacked_tree;

	$this->do("cd $dir; pkgmk -r / -d .")
		|| die "Error during pkgmk: $!\n";

	my $pkgname = $this->converted_name;
	my $name = $this->name."-".$this->version.".pkg";
	$this->do("pkgtrans $dir $name $pkgname >/dev/null 2>&1")
		|| die "Error during pkgtrans: $!\n";
	$this->do("mv", "$dir/$name", $name);
	return $name;
}

=head1 AUTHOR

Mark Hershberger <mah@everybody.org>

=cut

1
