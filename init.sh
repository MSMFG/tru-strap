#!/bin/bash

# Usage: init.sh --role webserver --environment prod1 --site a --repouser jimfdavies --reponame provtest-config

VERSION=0.0.1

if [ ${!#} == "--debug" ]
then
  function progress_bar {
  $@
  }
else
  function progress_bar {
    while :;do echo -n .;sleep 1;done &
    $@ > /dev/null
    kill $!; trap 'kill $!' SIGTERM
    echo -e "\e[0;32m done \e[0m"
  }
fi

# Install Puppet
# RHEL

echo -n "Installing Puppetlabs repo"
progress_bar yum install -y http://yum.puppetlabs.com/puppetlabs-release-el-6.noarch.rpm
echo -n "Installing Puppet"
progress_bar yum install -y puppet

# Process command line params

function print_version {
  echo $1 $2
}

function print_help {
  echo Heeelp.
}

function set_facter {
  export FACTER_$1=$2
  puppet apply -e "file { '/etc/facter': ensure => directory, mode => 0600 } -> \
                   file { '/etc/facter/facts.d': ensure => directory, mode => 0600 } -> \
                   file { '/etc/facter/facts.d/$1.txt': ensure => present, mode => 0600, content => '$1=$2' }" --logdest syslog > /dev/null
  echo -n "Facter says $1 is:"
  echo -e "\e[0;32m $(facter $1) \e[0m"
}

while test -n "$1"; do
  case "$1" in
  --help|-h)
    print_help
    exit
    ;;
  --version|-v)
    print_version $PROGNAME $VERSION
    exit
    ;;
  --role|-r)
    set_facter init_role $2
    shift
    ;;
  --environment|-e)
    set_facter init_env $2
    shift
    ;;
  --repouser|-u)
    set_facter init_repouser $2
    shift
    ;;
  --reponame|-n)
    set_facter init_reponame $2
    shift
    ;;
  --repoprivkeyfile|-k)
    set_facter init_repoprivkeyfile $2
    shift
    ;;
  --repobranch|-b)
    set_facter init_repobranch $2
    shift
    ;;
  --repodir|-d)
    set_facter init_repodir $2
    shift
    ;;
  --eyamlpubkeyfile|-j)
    set_facter init_eyamlpubkeyfile $2
    shift
    ;;
  --eyamlprivkeyfile|-m)
    set_facter init_eyamlprivkeyfile $2
    shift
    ;;
  --debug)
    shift
    ;;

  *)
    echo "Unknown argument: $1"
    print_help
    exit
    ;;
  esac
  shift
done

usagemessage="Error, USAGE: $(basename $0) --role|-r --environment|-e --repouser|-u --reponame|-n --repoprivkeyfile|-k [--repobranch|-b] [--repodir|-d] [--eyamlpubkeyfile|-j] [--eyamlprivkeyfile|-] [--help|-h] [--version|-v]"

# Define required parameters.
if [[ "$FACTER_init_role" == "" || "$FACTER_init_env" == "" || "$FACTER_init_repouser" == "" || "$FACTER_init_reponame" == "" || "$FACTER_init_repoprivkeyfile" == "" ]]; then
  echo $usagemessage
  exit 1
fi

# Set Git login params
echo "Injecting private ssh key"
GITHUB_PRI_KEY=$(cat $FACTER_init_repoprivkeyfile)
puppet apply -v -e "file {'ssh': path => '/root/.ssh/',ensure => directory} -> \
                    file {'id_rsa': path => '/root/.ssh/id_rsa',ensure => present, mode    => 0600, content => '$GITHUB_PRI_KEY'} -> \
                    file {'config': path => '/root/.ssh/config',ensure => present, mode    => 0644, content => 'StrictHostKeyChecking=no'} -> \
                    package { 'git': ensure => present }" > /dev/null

# Set some defaults if they aren't given on the command line.
[ -z "$FACTER_init_repobranch" ] && set_facter init_repobranch master
[ -z "$FACTER_init_repodir" ] && set_facter init_repodir /opt/$FACTER_init_reponame

# Clone private repo.
puppet apply -e "file { '$FACTER_init_repodir': ensure => absent, force => true }" > /dev/null
echo "Cloning $FACTER_init_repouser/$FACTER_init_reponame repo"
git clone -b $FACTER_init_repobranch git@github.com:$FACTER_init_repouser/$FACTER_init_reponame.git $FACTER_init_repodir

# Exit if the clone fails
if [ ! -d "$FACTER_init_repodir" ]
then
  echo "Failed to clone git@github.com:$FACTER_init_repouser/$FACTER_init_reponame.git" && exit 1
fi

# Link /etc/puppet to our private repo.
PUPPET_DIR="$FACTER_init_repodir/puppet"
rm -rf /etc/puppet ; ln -s $PUPPET_DIR /etc/puppet
puppet apply -e "file { '/etc/hiera.yaml': ensure => link, target => '/etc/puppet/hiera.yaml' }" > /dev/null

# Install eyaml gem
echo -n "Installing eyaml gem"
progress_bar gem install hiera-eyaml --no-ri --no-rdoc

# If no eyaml keys have been provided, create some
if [ -z "$FACTER_init_eyamlpubkeyfile" ] && [ -z "$FACTER_init_eyamlprivkeyfile" ] && [ ! -d "/etc/puppet/secure/keys" ]
then
  puppet apply -v -e "file {'/etc/puppet/secure': ensure => directory, mode => 0500} -> \
                      file {'/etc/puppet/secure/keys': ensure => directory, mode => 0500}" > /dev/null
  cd /etc/puppet/secure
  echo -n "Creating eyaml key pair"
  progress_bar eyaml createkeys
else
# Or use the ones provided
  echo "Injecting eyaml keys"
  EYAML_PUB_KEY=$(cat $FACTER_init_eyamlpubkeyfile)
  EYAML_PRI_KEY=$(cat $FACTER_init_eyamlprivkeyfile)
  puppet apply -v -e "file {'/etc/puppet/secure': ensure => directory, mode => 0500} -> \
                      file {'/etc/puppet/secure/keys': ensure => directory, mode => 0500} -> \
                      file {'/etc/puppet/secure/keys/public_key.pkcs7.pem': ensure => present, mode => 0400, content => '$EYAML_PUB_KEY'} -> \
                      file {'/etc/puppet/secure/keys/private_key.pkcs7.pem': ensure => present, mode => 0400, content => '$EYAML_PRI_KEY'}" > /dev/null
fi

# # Install RVM to manage Ruby versions
echo "Installing RVM and latest Ruby"
curl -sSL https://get.rvm.io | bash
source /usr/local/rvm/scripts/rvm
#RUBY_VERSION=`rvm list remote | grep ruby | tail -1 | awk '{ print $NF }'`
RUBY_VERSION=ruby-2.1.2
rvm install $RUBY_VERSION --max-time 30

# # Use RVM to select specific Ruby version (2.1+) for use with Librarian-puppet
rvm use $RUBY_VERSION

# Install and execute Librarian Puppet
# Create symlink to role specific Puppetfile
ENV_BASE_PUPPETFILE=${FACTER_init_env}/Puppetfile.base
ENV_ROLE_PUPPETFILE=${FACTER_init_env}/Puppetfile.${FACTER_init_role}
BASE_PUPPETFILE=Puppetfile.base
ROLE_PUPPETFILE=Puppetfile.${FACTER_init_role}
if [ -f /etc/puppet/Puppetfiles/$ENV_BASE_PUPPETFILE ]; then
  BASE_PUPPETFILE=$ENV_BASE_PUPPETFILE
fi
if [ -f /etc/puppet/Puppetfiles/$ENV_ROLE_PUPPETFILE ]; then
  ROLE_PUPPETFILE=$ENV_ROLE_PUPPETFILE
fi
rm -f /etc/puppet/Puppetfile ; cat /etc/puppet/Puppetfiles/$BASE_PUPPETFILE /etc/puppet/Puppetfiles/$ROLE_PUPPETFILE > /etc/puppet/Puppetfile
gem sources -a http://rubygems.org
echo -n "Installing librarian-puppet"
progress_bar gem install librarian-puppet --no-ri --no-rdoc
echo -n "Installing Puppet gem"
progress_bar gem install puppet --no-ri --no-rdoc
cd $PUPPET_DIR
echo -n "Installing Puppet modules"
progress_bar librarian-puppet install --verbose
librarian-puppet show

# # Use RVM to revert Ruby version to back to system default (1.8.7)
rvm --default use system

# Make things happen.
echo ""
echo "Running puppet apply"
puppet apply /etc/puppet/manifests/site.pp
PUPPET_EXIT=$?

# Print out the top 10 slowest Puppet resources
echo ""
echo "Top 10 slowest Puppet resources"
echo "==============================="
PERFORMANCE_DATA=( $(grep evaluation_time /var/lib/puppet/reports/*/*.yaml | awk '{print $3}' | sort -n | tail -10 ) )
for i in ${PERFORMANCE_DATA[*]}
do
  echo -n "${i}s - "
  echo $(grep -B 3 $i /var/lib/puppet/reports/*/*.yaml | head -1 | awk '{print $2 $3}' )
done | tac

exit $PUPPET_EXIT
