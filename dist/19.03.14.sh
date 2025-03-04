#!/bin/sh
set -e

CHANNEL="stable"

docker_version=19.03.14
apt_url="https://apt.dockerproject.org"
yum_url="https://yum.dockerproject.org"
gpg_fingerprint="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"

key_servers="
ha.pool.sks-keyservers.net
pgp.mit.edu
keyserver.ubuntu.com
"

rhel_repos="
rhel-7-server-extras-rpms
rhel-7-server-rhui-extras-rpms
rhui-REGION-rhel-server-extras
rhui-rhel-7-server-rhui-extras-rpms
rhui-rhel-7-for-arm-64-extras-rhui-rpms
"

ol_repos="
ol7_addons
"

mirror=''
while [ $# -gt 0 ]; do
	case "$1" in
		--mirror)
			mirror="$2"
			shift
			;;
		*)
			echo "Illegal option $1"
			;;
	esac
	shift $(( $# > 0 ? 1 : 0 ))
done

case "$mirror" in
	AzureChinaCloud)
		apt_url="https://mirror.azure.cn/docker-engine/apt"
		yum_url="https://mirror.azure.cn/docker-engine/yum"
		;;
	Aliyun)
		apt_url="https://mirrors.aliyun.com/docker-engine/apt"
		yum_url="https://mirrors.aliyun.com/docker-engine/yum"
		;;
esac

command_exists() {
	command -v "$@" > /dev/null 2>&1
}

echo_docker_as_nonroot() {
	if command_exists docker && [ -e /var/run/docker.sock ]; then
		(
			set -x
			$sh_c 'docker version'
		) || true
	fi
	your_user=your-user
	[ "$user" != 'root' ] && your_user="$user"
	# intentionally mixed spaces and tabs here -- tabs are stripped by "<<-EOF", spaces are kept in the output
	cat <<-EOF

	If you would like to use Docker as a non-root user, you should now consider
	adding your user to the "docker" group with something like:

	  sudo usermod -aG docker $your_user

	Remember that you will have to log out and back in for this to take effect!

	WARNING: Adding a user to the "docker" group will grant the ability to run
	         containers which can be used to obtain root privileges on the
	         docker host.
	         Refer to https://docs.docker.com/engine/security/security/#docker-daemon-attack-surface
	         for more information.

	EOF
}

# Check if this is a forked Linux distro
check_forked() {

	# Check for lsb_release command existence, it usually exists in forked distros
	if command_exists lsb_release; then
		# Check if the `-u` option is supported
		set +e
		lsb_release -a -u > /dev/null 2>&1
		lsb_release_exit_code=$?
		set -e

		# Check if the command has exited successfully, it means we're in a forked distro
		if [ "$lsb_release_exit_code" = "0" ]; then
			# Print info about current distro
			cat <<-EOF
			You're using '$lsb_dist' version '$dist_version'.
			EOF

			# Get the upstream release info
			lsb_dist=$(lsb_release -a -u 2>&1 | tr '[:upper:]' '[:lower:]' | grep -E 'id' | cut -d ':' -f 2 | tr -d '[[:space:]]')
			dist_version=$(lsb_release -a -u 2>&1 | tr '[:upper:]' '[:lower:]' | grep -E 'codename' | cut -d ':' -f 2 | tr -d '[[:space:]]')

			# Print info about upstream distro
			cat <<-EOF
			Upstream release is '$lsb_dist' version '$dist_version'.
			EOF
		else
			if [ -r /etc/debian_version ] && [ "$lsb_dist" != "ubuntu" ] && [ "$lsb_dist" != "raspbian" ]; then
				# We're Debian and don't even know it!
				lsb_dist=debian
				dist_version="$(cat /etc/debian_version | sed 's/\/.*//' | sed 's/\..*//')"
				case "$dist_version" in
					10)
						dist_version="buster"
					;;
					9)
						dist_version="stretch"
					;;
					8|'Kali Linux 2')
						dist_version="jessie"
					;;
					7)
						dist_version="wheezy"
					;;
				esac
			fi
		fi
	fi
}

semverParse() {
	major="${1%%.*}"
	minor="${1#$major.}"
	minor="${minor%%.*}"
	patch="${1#$major.$minor.}"
	patch="${patch%%[-.]*}"
}

deprecation_notice() {
	echo
	echo
	echo "  WARNING: $1 is no longer updated @ $url"
	echo "           Installing the legacy docker-engine package..."
	echo
	echo
	sleep 10;
}

adjust_repo_releasever() {
	DOWNLOAD_URL="https://download.docker.com"
	case $1 in
	7*)
		releasever=7
		;;
	8*)
		releasever=8
		;;
	*)
		# fedora, or unsupported
		return
		;;
	esac

	for channel in "stable" "test" "nightly"; do
		$sh_c "$config_manager --setopt=docker-ce-${channel}.baseurl=${DOWNLOAD_URL}/linux/centos/${releasever}/\\\$basearch/${channel} --save";
		$sh_c "$config_manager --setopt=docker-ce-${channel}-debuginfo.baseurl=${DOWNLOAD_URL}/linux/centos/${releasever}/debug-\\\$basearch/${channel} --save";
		$sh_c "$config_manager --setopt=docker-ce-${channel}-source.baseurl=${DOWNLOAD_URL}/linux/centos/${releasever}/source/${channel} --save";
	done
}

do_install() {

	architecture=$(uname -m)
	case $architecture in
		# officially supported
		amd64|aarch64|arm64|x86_64)
			;;
		# unofficially supported with available repositories
		armv6l|armv7l)
			;;
		# unofficially supported without available repositories
		ppc64le|s390x)
			cat 1>&2 <<-EOF
			Error: This install script does not support $architecture, because no
			$architecture package exists in Docker's repositories.

			Other install options include checking your distribution's package repository
			for a version of Docker, or building Docker from source.
			EOF
			exit 1
			;;
		# not supported
		*)
			cat >&2 <<-EOF
			Error: $architecture is not a recognized platform.
			EOF
			exit 1
			;;
	esac

	if command_exists docker; then
		version="$(docker -v | cut -d ' ' -f3 | cut -d ',' -f1)"
		MAJOR_W=1
		MINOR_W=10

		semverParse $version

		shouldWarn=0
		if [ $major -lt $MAJOR_W ]; then
			shouldWarn=1
		fi

		if [ $major -le $MAJOR_W ] && [ $minor -lt $MINOR_W ]; then
			shouldWarn=1
		fi

		cat >&2 <<-'EOF'
			Warning: the "docker" command appears to already exist on this system.

			If you already have Docker installed, this script can cause trouble, which is
			why we're displaying this warning and provide the opportunity to cancel the
			installation.

			If you installed the current Docker package using this script and are using it
		EOF

		if [ $shouldWarn -eq 1 ]; then
			cat >&2 <<-'EOF'
			again to update Docker, we urge you to migrate your image store before upgrading
			to v1.10+.

			You can find instructions for this here:
			https://github.com/docker/docker/wiki/Engine-v1.10.0-content-addressability-migration
			EOF
		else
			cat >&2 <<-'EOF'
			again to update Docker, you can safely ignore this message.
			EOF
		fi

		cat >&2 <<-'EOF'

			You may press Ctrl+C now to abort this script.
		EOF
		( set -x; sleep 20 )
	fi

	user="$(id -un 2>/dev/null || true)"

	sh_c='sh -c'
	if [ "$user" != 'root' ]; then
		if command_exists sudo; then
			sh_c='sudo -E sh -c'
		elif command_exists su; then
			sh_c='su -c'
		else
			cat >&2 <<-'EOF'
			Error: this installer needs the ability to run commands as root.
			We are unable to find either "sudo" or "su" available to make this happen.
			EOF
			exit 1
		fi
	fi

	curl=''
	if command_exists curl; then
		curl='curl -sSL'
	elif command_exists wget; then
		curl='wget -qO-'
	elif command_exists busybox && busybox --list-modules | grep -q wget; then
		curl='busybox wget -qO-'
	fi

	# check to see which repo they are trying to install from
	if [ -z "$repo" ]; then
		repo='main'
		if [ "https://test.docker.com/" = "$url" ]; then
			repo='testing'
		elif [ "https://experimental.docker.com/" = "$url" ]; then
			repo='experimental'
		fi
	fi

	# perform some very rudimentary platform detection
	lsb_dist=''
	dist_version=''
	if command_exists lsb_release; then
		lsb_dist="$(lsb_release -si)"
	fi
	if [ -z "$lsb_dist" ] && [ -r /etc/lsb-release ]; then
		lsb_dist="$(. /etc/lsb-release && echo "$DISTRIB_ID")"
	fi
	if [ -z "$lsb_dist" ] && [ -r /etc/debian_version ]; then
		lsb_dist='debian'
	fi
	if [ -z "$lsb_dist" ] && [ -r /etc/fedora-release ]; then
		lsb_dist='fedora'
	fi
	if [ -z "$lsb_dist" ] && [ -r /etc/oracle-release ]; then
		lsb_dist='oracleserver'
	fi
	if [ -z "$lsb_dist" ] && [ -r /etc/centos-release ]; then
		lsb_dist='centos'
	fi
	if [ -z "$lsb_dist" ] && [ -r /etc/redhat-release ]; then
		lsb_dist='redhat'
	fi
	if [ -z "$lsb_dist" ] && [ -r /etc/os-release ]; then
		lsb_dist="$(. /etc/os-release && echo "$ID")"
	fi

	lsb_dist="$(echo "$lsb_dist" | tr '[:upper:]' '[:lower:]')"

	# Special case redhatenterpriseserver and redhatenterprise
	if [ "${lsb_dist}" = "redhatenterpriseserver" ] || [ "${lsb_dist}" = "redhatenterprise" ]; then
		# Set it to redhat, it will be changed to centos below anyways
		lsb_dist='redhat'
	fi

	case "$lsb_dist" in

		ubuntu)
			if command_exists lsb_release; then
				dist_version="$(lsb_release --codename | cut -f2)"
			fi
			if [ -z "$dist_version" ] && [ -r /etc/lsb-release ]; then
				dist_version="$(. /etc/lsb-release && echo "$DISTRIB_CODENAME")"
			fi
		;;

		debian|raspbian)
			dist_version="$(cat /etc/debian_version | sed 's/\/.*//' | sed 's/\..*//')"
			case "$dist_version" in
				9)
					dist_version="stretch"
				;;
				8)
					dist_version="jessie"
				;;
				7)
					dist_version="wheezy"
				;;
			esac
		;;

		oracleserver)
			# need to switch lsb_dist to match yum repo URL
			lsb_dist="oraclelinux"
			dist_version="$(rpm -q --whatprovides redhat-release --queryformat "%{VERSION}\n" | sed 's/\/.*//' | sed 's/\..*//' | sed 's/Server*//')"
		;;

		fedora|centos|redhat)
			dist_version="$(rpm -q --whatprovides ${lsb_dist}-release --queryformat "%{VERSION}\n" | sed 's/\/.*//' | sed 's/\..*//' | sed 's/Server*//' | sort | tail -1)"
		;;

		*)
			if command_exists lsb_release; then
				dist_version="$(lsb_release --codename | cut -f2)"
			fi
			if [ -z "$dist_version" ] && [ -r /etc/os-release ]; then
				dist_version="$(. /etc/os-release && echo "$VERSION_ID")"
			fi
		;;


	esac

	# Check if this is a forked Linux distro
	check_forked

	# Run setup for each distro accordingly
	case "$lsb_dist" in
		ubuntu|debian)
			pre_reqs="apt-transport-https ca-certificates curl"
			if [ "$lsb_dist" = "debian" ] && [ "$dist_version" = "wheezy" ]; then
				pre_reqs="$pre_reqs python-software-properties"
				backports="deb http://ftp.debian.org/debian wheezy-backports main"
				if ! grep -Fxq "$backports" /etc/apt/sources.list; then
					(set -x; $sh_c "echo \"$backports\" >> /etc/apt/sources.list")
				fi
			else
				pre_reqs="$pre_reqs software-properties-common"
			fi
			if ! command -v gpg > /dev/null; then
				pre_reqs="$pre_reqs gnupg"
			fi
			apt_repo="deb [arch=$(dpkg --print-architecture)] https://download.docker.com/linux/$lsb_dist $dist_version $CHANNEL"
			(
				set -x
				$sh_c 'apt-get update'
				$sh_c "apt-get install -y -q $pre_reqs"
				curl -fsSl "https://download.docker.com/linux/$lsb_dist/gpg" | $sh_c 'apt-key add -'
				$sh_c "add-apt-repository \"$apt_repo\""
				if [ "$lsb_dist" = "debian" ] && [ "$dist_version" = "wheezy" ]; then
					$sh_c 'sed -i "/deb-src.*download\.docker/d" /etc/apt/sources.list'
				fi
				$sh_c 'apt-get update'
				pkg_version=$(apt-cache madison docker-ce | grep ${docker_version} | head -n 1 | cut -d ' ' -f 4)
				$sh_c "apt-get install -y -q docker-ce=${pkg_version} docker-ce-cli=${pkg_version}"
			)
			echo_docker_as_nonroot
			exit 0
			;;
		centos|fedora|redhat|oraclelinux)
			yum_repo="https://download.docker.com/linux/centos/docker-ce.repo"
			if [ "$lsb_dist" = "fedora" ]; then
				if [ "$dist_version" -lt "24" ]; then
					echo "Error: Only Fedora >=24 are supported by $url"
					exit 1
				fi
				pkg_manager="dnf"
				config_manager="dnf config-manager"
				enable_channel_flag="--set-enabled"
				pre_reqs="dnf-plugins-core"
			else
				pkg_manager="yum"
				config_manager="yum-config-manager"
				enable_channel_flag="--enable"
				pre_reqs="yum-utils iptables"
			fi
			(
				set -x
				$sh_c "$pkg_manager install -y -q $pre_reqs"
			        if [ "$lsb_dist" = "redhat" ]; then
                                        case $dist_version in
                                                7*)
                                                        for rhel_repo in $rhel_repos ; do
                                                                $sh_c "$config_manager $enable_channel_flag $rhel_repo"
                                                        done
                                                        ;;
                                        esac
                                fi
			        if [ "$lsb_dist" = "oraclelinux" ]; then
                                        case $dist_version in
                                                7*)
                                                        for ol_repo in $ol_repos ; do
                                                                $sh_c "$config_manager $enable_channel_flag $ol_repo"
                                                        done
                                                        ;;
                                        esac
                                fi

				$sh_c "$config_manager --add-repo $yum_repo"
				if [ "$CHANNEL" != "stable" ]; then
					echo "Info: Enabling channel '$CHANNEL' for docker-ce repo"
					$sh_c "$config_manager $enable_channel_flag docker-ce-$CHANNEL"
				fi
				adjust_repo_releasever "$dist_version"
				case $dist_version in
					7*)
						$sh_c "$pkg_manager makecache fast"
						;;
					8*)
						$sh_c "$pkg_manager makecache"
						;;
				esac
				$sh_c "$pkg_manager install -y -q docker-ce-${docker_version} docker-ce-cli-${docker_version}"
				if [ -d '/run/systemd/system' ]; then
					$sh_c 'service docker start'
				else
					$sh_c 'systemctl start docker'
				fi
			)
			echo_docker_as_nonroot
			exit 0
			;;
		raspbian)
			deprecation_notice "$lsb_dist"
			export DEBIAN_FRONTEND=noninteractive

			did_apt_get_update=
			apt_get_update() {
				if [ -z "$did_apt_get_update" ]; then
					( set -x; $sh_c 'sleep 3; apt-get update' )
					did_apt_get_update=1
				fi
			}

			if [ "$lsb_dist" != "raspbian" ]; then
				# aufs is preferred over devicemapper; try to ensure the driver is available.
				if ! grep -q aufs /proc/filesystems && ! $sh_c 'modprobe aufs'; then
					if uname -r | grep -q -- '-generic' && dpkg -l 'linux-image-*-generic' | grep -qE '^ii|^hi' 2>/dev/null; then
						kern_extras="linux-image-extra-$(uname -r) linux-image-extra-virtual"

						apt_get_update
						( set -x; $sh_c 'sleep 3; apt-get install -y -q '"$kern_extras" ) || true

						if ! grep -q aufs /proc/filesystems && ! $sh_c 'modprobe aufs'; then
							echo >&2 'Warning: tried to install '"$kern_extras"' (for AUFS)'
							echo >&2 ' but we still have no AUFS.  Docker may not work. Proceeding anyways!'
							( set -x; sleep 10 )
						fi
					else
						echo >&2 'Warning: current kernel is not supported by the linux-image-extra-virtual'
						echo >&2 ' package.  We have no AUFS support.  Consider installing the packages'
						echo >&2 ' "linux-image-virtual" and "linux-image-extra-virtual" for AUFS support.'
						( set -x; sleep 10 )
					fi
				fi
			fi

			# install apparmor utils if they're missing and apparmor is enabled in the kernel
			# otherwise Docker will fail to start
			if [ "$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null)" = 'Y' ]; then
				if command -v apparmor_parser >/dev/null 2>&1; then
					echo 'apparmor is enabled in the kernel and apparmor utils were already installed'
				else
					echo 'apparmor is enabled in the kernel, but apparmor_parser is missing. Trying to install it..'
					apt_get_update
					( set -x; $sh_c 'sleep 3; apt-get install -y -q apparmor' )
				fi
			fi

			if [ ! -e /usr/lib/apt/methods/https ]; then
				apt_get_update
				( set -x; $sh_c 'sleep 3; apt-get install -y -q apt-transport-https ca-certificates' )
			fi
			if [ -z "$curl" ]; then
				apt_get_update
				( set -x; $sh_c 'sleep 3; apt-get install -y -q curl ca-certificates' )
				curl='curl -sSL'
			fi
			if ! command -v gpg > /dev/null; then
				apt_get_update
				( set -x; $sh_c 'sleep 3; apt-get install -y -q gnupg2 || apt-get install -y -q gnupg' )
			fi

			# dirmngr is a separate package in ubuntu yakkety; see https://bugs.launchpad.net/ubuntu/+source/apt/+bug/1634464
			if ! command -v dirmngr > /dev/null; then
				apt_get_update
				( set -x; $sh_c 'sleep 3; apt-get install -y -q dirmngr' )
			fi

			(
			set -x
                        for key_server in $key_servers ; do
                                $sh_c "apt-key adv --keyserver hkp://${key_server}:80 --recv-keys ${gpg_fingerprint}" && break
                        done
                        $sh_c "apt-key adv -k ${gpg_fingerprint} >/dev/null"
			$sh_c "mkdir -p /etc/apt/sources.list.d"
			$sh_c "echo deb \[arch=$(dpkg --print-architecture)\] ${apt_url}/repo ${lsb_dist}-${dist_version} ${repo} > /etc/apt/sources.list.d/docker.list"
			$sh_c 'sleep 3; apt-get update; apt-get install -y -q docker-engine'
			)
			echo_docker_as_nonroot
			exit 0
			;;
		rancheros)
			(
			set -x
			$sh_c "sleep 3;ros engine list --update"
			engine_version="$(sudo ros engine list | awk '{print $2}' | grep ${docker_version} | tail -n 1)"
			if [ "$engine_version" != "" ]; then
				$sh_c "ros engine switch -f $engine_version"
			fi
			)
			exit 0
			;;
	esac

	# intentionally mixed spaces and tabs here -- tabs are stripped by "<<-'EOF'", spaces are kept in the output
	cat >&2 <<-'EOF'

	Either your platform is not easily detectable or is not supported by this
	installer script.
	Please visit the following URL for more detailed installation instructions:

	https://docs.docker.com/engine/installation/

	EOF
	exit 1
}

# wrapped up in a function so that we have some protection against only getting
# half the file during "curl | sh"
do_install
