#!/bin/bash

function yum_install {
  PACKAGE_LIST=""
  for i in "$@"
  do
    yum --noplugins list installed "$i" > /dev/null 2>&1
    if [ $? == 0 ]
    then
      echo "$i is already installed"
    else
      PACKAGE_LIST="$PACKAGE_LIST $i"
    fi
  done

  if [ -n "$PACKAGE_LIST" ]
  then
    yum install -y $(echo "$PACKAGE_LIST" | xargs)
  fi
}

function gem_install {
  for i in "$@"
  do
    gem list --local $(echo "$i" | cut -d ':' -f 1)  | grep $(echo "$i" | cut -d ':' -f 1) > /dev/null 2>&1
    if [ $? == 0 ]
    then
      echo "$i is already installed"
    else
      GEM_LIST="$GEM_LIST $i"
    fi
  done
  if [ -n "$GEM_LIST" ]
  then
    gem install $(echo "$GEM_LIST" | xargs) --no-ri --no-rdoc
  fi
}

# Check the version of Ruby before we don anything
ruby -v  > /dev/null 2>&1
if [ $? -ne 0 ]
then
  yum install -y https://s3-eu-west-1.amazonaws.com/msm-public-repo/ruby/ruby-2.1.5-2.el6.x86_64.rpm
fi

if [ $(ruby -v | awk '{print $2}' | cut -d '.' -f 1) -lt 2 ]
then
  yum install -y https://s3-eu-west-1.amazonaws.com/msm-public-repo/ruby/ruby-2.1.5-2.el6.x86_64.rpm
fi


echo "Installing required yum packages"
yum_install augeas-devel ncurses-devel gcc gcc-c++ curl git

echo "Installing required gems"
gem_install puppet:3.7.4 hiera facter ruby-augeas hiera-eyaml

GEM_SOURCES=
tmp_sources=false
for i in "$@"
do
  if [ "$tmp_sources" == "true" ];then
    GEM_SOURCES=$i
    break
    tmp_sources=false
  fi
  if [ "$i" == "--gemsources" ];then
    tmp_sources=true
  fi
done

if [ ! -z "$GEM_SOURCES" ]; then
  echo "Re-configuring gem sources"
  # Remove the old sources
  OLD_GEM_SOURCES=$(gem sources --list | tail -n+3 | tr '\n' ' ')
  for i in $OLD_GEM_SOURCES
  do
    gem sources -r $i
  done

  # Add the replacement sources
  OIFS=$IFS && IFS=','
  for i in $GEM_SOURCES
  do
    MAX_RETRIES=5
    export attempts=1
    exit_code=1
    while [ $exit_code -ne 0 ] && [ $attempts -le ${MAX_RETRIES} ]
    do
      gem sources -a $i
      exit_code=$?
      if [ $exit_code -ne 0 ]; then
        sleep_time=$((attempts * 10))
        echo Sleeping for ${sleep_time}s before retrying ${attempts}/${MAX_RETRIES}
        sleep ${sleep_time}s
        attempts=$((attempts + 1))
      fi
    done
  done
  IFS=$OIFS
fi

# Process command line params
function print_version {
  echo $1 $2
}

function print_help {
  echo Heeelp.
}

function set_facter {
  export FACTER_$1=$2
  if [ ! -d /etc/facter ]
  then
    mkdir -p /etc/facter/facts.d
  fi
  echo "$1=$2" > /etc/facter/facts.d/$1.txt
  chmod -R 600 /etc/facter
  cat /etc/facter/facts.d/$1.txt
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
  --moduleshttpcache|-c)
    set_facter init_moduleshttpcache $2
    shift
    ;;
  --gemsources)
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

usagemessage="Error, USAGE: $(basename $0) --role|-r --environment|-e --repouser|-u --reponame|-n --repoprivkeyfile|-k [--repobranch|-b] [--repodir|-d] [--eyamlpubkeyfile|-j] [--eyamlprivkeyfile|-m] [--gemsources|-s] [--help|-h] [--version|-v]"

# Define required parameters.
if [[ "$FACTER_init_role" == "" || "$FACTER_init_env" == "" || "$FACTER_init_repouser" == "" || "$FACTER_init_reponame" == "" || "$FACTER_init_repoprivkeyfile" == "" ]]; then
  echo $usagemessage
  exit 1
fi

# Set Git login params
echo "Injecting private ssh key"
GITHUB_PRI_KEY=$(cat $FACTER_init_repoprivkeyfile)
if [ ! -d /root/.ssh ]
then
  mkdir /root/.ssh
  chmod 600 /root/.ssh
fi
echo "$GITHUB_PRI_KEY" > /root/.ssh/id_rsa
echo "StrictHostKeyChecking=no" > /root/.ssh/config
chmod -R 600 /root/.ssh

# Set some defaults if they aren't given on the command line.
[ -z "$FACTER_init_repobranch" ] && set_facter init_repobranch master
[ -z "$FACTER_init_repodir" ] && set_facter init_repodir /opt/$FACTER_init_reponame

# Clone private repo.
echo "Cloning $FACTER_init_repouser/$FACTER_init_reponame repo"
rm -rf $FACTER_init_repodir
git clone -b $FACTER_init_repobranch git@github.com:$FACTER_init_repouser/$FACTER_init_reponame.git $FACTER_init_repodir

# Exit if the clone fails
if [ ! -d "$FACTER_init_repodir" ]
then
  echo "Failed to clone git@github.com:$FACTER_init_repouser/$FACTER_init_reponame.git" && exit 1
fi

# Link /etc/puppet to our private repo.
PUPPET_DIR="$FACTER_init_repodir/puppet"
rm -rf /etc/puppet > /dev/null 2>&1
rm /etc/hiera.yaml > /dev/null 2>&1
ln -s $PUPPET_DIR /etc/puppet
ln -s /etc/puppet/hiera.yaml /etc/hiera.yaml

# If no eyaml keys have been provided, create some
if [ -z "$FACTER_init_eyamlpubkeyfile" ] && [ -z "$FACTER_init_eyamlprivkeyfile" ] && [ ! -d "/etc/puppet/secure/keys" ]
then
  if [ ! -d /etc/puppet/secure/keys ]
  then
    mkdir -p /etc/puppet/secure/keys
    chmod -R 500 /etc/puppet/secure
  fi
  cd /etc/puppet/secure
  echo -n "Creating eyaml key pair"
  eyaml createkeys
else
# Or use the ones provided
  echo "Injecting eyaml keys"
  EYAML_PUB_KEY=$(cat $FACTER_init_eyamlpubkeyfile)
  EYAML_PRI_KEY=$(cat $FACTER_init_eyamlprivkeyfile)
  mkdir -p /etc/puppet/secure/keys
  echo "$EYAML_PUB_KEY" > /etc/puppet/secure/keys/public_key.pkcs7.pem
  echo "$EYAML_PRI_KEY" > /etc/puppet/secure/keys/private_key.pkcs7.pem
  chmod -R 500 /etc/puppet/secure
  chmod 400 /etc/puppet/secure/keys/*.pem
fi

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
PUPPETFILE=/etc/puppet/Puppetfile
rm -f $PUPPETFILE ; cat /etc/puppet/Puppetfiles/$BASE_PUPPETFILE /etc/puppet/Puppetfiles/$ROLE_PUPPETFILE > $PUPPETFILE


PUPPETFILE_MD5SUM=$(md5sum $PUPPETFILE | cut -d " " -f 1)
MODULE_ARCH=${FACTER_init_role}.$PUPPETFILE_MD5SUM.tar.gz

cd $PUPPET_DIR

if [[ ! -z ${FACTER_init_moduleshttpcache} && "200" == $(curl ${FACTER_init_moduleshttpcache}/$MODULE_ARCH  --head --silent | head -n 1 | cut -d ' ' -f 2) ]]; then
  echo "Downloading pre-packed Puppet modules from cache..."
  curl -s -o modules.tar.gz ${FACTER_init_moduleshttpcache}/$MODULE_ARCH
  tar zxpf modules.tar.gz
  echo "================="
  echo "Unpacked modules:"
  find ./modules -maxdepth 1 -type d | cut -d '/' -f 3
  echo "================="
else
  echo -n "Installing Puppet modules"
  gem_install librarian-puppet
  librarian-puppet install --verbose
  librarian-puppet show
fi

# Make things happen.
export LC_ALL=en_GB.utf8
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
