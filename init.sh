#!/bin/bash
# Tru-Strap: prepare an instance for a Puppet run

main() {
    parse_args "$@"
    setup_rhel7_repo
    install_yum_deps
    install_ruby
    set_gemsources "$@"
    install_gem_deps
    inject_ssh_key
    clone_git_repo
    symlink_puppet_dir
    inject_eyaml_keys
    fetch_puppet_modules
    run_puppet
}

# Parse the commmand line arguments
parse_args() {
  while [[ -n "${1}" ]] ; do
    case "${1}" in
    --help|-h)
      print_help
      exit
      ;;
    --version|-v)
      print_version "${PROGNAME}" "${VERSION}"
      exit
      ;;
    --role|-r)
      set_facter init_role "${2}"
      shift
      ;;
    --environment|-e)
      set_facter init_env "${2}"
      shift
      ;;
    --repouser|-u)
      set_facter init_repouser "${2}"
      shift
      ;;
    --reponame|-n)
      set_facter init_reponame "${2}"
      shift
      ;;
    --repoprivkeyfile|-k)
      cat "$2" > /dev/null || exit $?
      set_facter init_repoprivkeyfile "${2}"
      shift
      ;;
    --repobranch|-b)
      set_facter init_repobranch "${2}"
      shift
      ;;
    --repodir|-d)
      set_facter init_repodir "${2}"
      shift
      ;;
    --eyamlpubkeyfile|-j)
      cat "$2" > /dev/null || exit $?
      set_facter init_eyamlpubkeyfile "${2}"
      shift
      ;;
    --eyamlprivkeyfile|-m)
      cat "$2" > /dev/null || exit $?
      set_facter init_eyamlprivkeyfile "${2}"
      shift
      ;;
    --moduleshttpcache|-c)
      set_facter init_moduleshttpcache "${2}"
      shift
      ;;
    --passwd|-p)
      PASSWD="${2}"
      shift
      ;;
    # FIXME: Discarded option. Remove it?
    --gemsources)
      shift
      ;;
    # FIXME: Discarded option. Remove it?
    --debug)
      shift
      ;;

    *)
      echo "Unknown argument: ${1}"
      print_help
      exit
      ;;
    esac
    shift
  done

  usagemessage="Error, USAGE: $(basename "${0}") --role|-r --environment|-e --repouser|-u --reponame|-n --repoprivkeyfile|-k [--repobranch|-b] [--repodir|-d] [--eyamlpubkeyfile|-j] [--eyamlprivkeyfile|-m] [--gemsources|-s] [--help|-h] [--version|-v]"

  # Define required parameters.
  if [[ -z "${FACTER_init_role}" || -z "${FACTER_init_env}" || -z "${FACTER_init_repouser}" || -z "${FACTER_init_reponame}" || -z "${FACTER_init_repoprivkeyfile}" ]]; then
    echo "${usagemessage}"
    exit 1
  fi

  # Set some defaults if they aren't given on the command line.
  [[ -z "${FACTER_init_repobranch}" ]] && set_facter init_repobranch master
  [[ -z "${FACTER_init_repodir}" ]] && set_facter init_repodir /opt/"${FACTER_init_reponame}"
}

# Install yum packages if they're not already installed
yum_install() {
  PACKAGE_LIST=""
  for i in "$@"
  do
    yum --noplugins list installed "${i}" > /dev/null 2>&1
    if [[ $? == 0 ]]; then
      echo "${i} is already installed"
    else
      PACKAGE_LIST="${PACKAGE_LIST} ${i}"
    fi
  done

  if [[ -n "${PACKAGE_LIST}" ]]; then
    yum install -y $(echo "${PACKAGE_LIST}" | xargs)
  fi
}

# Install Ruby gems if they're not already installed
gem_install() {
  for i in "$@"
  do
    gem list --local $(echo "${i}" | cut -d ':' -f 1)  | grep $(echo "${i}" | cut -d ':' -f 1) > /dev/null 2>&1
    if [[ $? == 0 ]]; then
      echo "${i} is already installed"
    else
      GEM_LIST="${GEM_LIST} ${i}"
    fi
  done
  if [[ -n "$GEM_LIST" ]]; then
    gem install $(echo "$GEM_LIST" | xargs) --no-ri --no-rdoc
  fi
}

print_version() {
  echo "${1}" "${2}"
}

print_help() {
  echo Heeelp.
}

# Set custom facter facts
set_facter() {
  export FACTER_$1="${2}"
  if [[ ! -d /etc/facter ]]; then
    mkdir -p /etc/facter/facts.d
  fi
  echo "${1}=${2}" > /etc/facter/facts.d/"${1}".txt
  chmod -R 600 /etc/facter
  cat /etc/facter/facts.d/"${1}".txt
}

setup_rhel7_repo() {
  yum_install redhat-lsb-core
  dist=$(lsb_release -is)
  majorversion=$(lsb_release -rs | cut -f1 -d.)
  if [[ "$majorversion" == "7" ]] && [[ "$dist" == "RedHatEnterpriseServer" ]]; then
    echo "RedHat Enterprise version 7- adding extra repo for *-devel"
    yum_install yum-utils
    yum-config-manager --enable rhui-REGION-rhel-server-optional
  fi

}
install_ruby() {
  majorversion=$(lsb_release -rs | cut -f1 -d.)
  if [[ "$majorversion" == "6" ]]; then
  echo "Linux Major Version 6"
   ruby -v  > /dev/null 2>&1
   if [[ $? -ne 0 ]] || [[ $(ruby -v | awk '{print $2}' | cut -d '.' -f 1) -lt 2 ]]; then
     yum remove -y ruby-*
     yum install -y https://s3-eu-west-1.amazonaws.com/msm-public-repo/ruby/ruby-2.1.5-2.el6.x86_64.rpm
   fi
  elif [[ "$majorversion" == "7" ]]; then
    echo "Linux Major version 7"
    yum_install ruby ruby-devel
  fi
}

# Set custom gem sources
set_gemsources() {
  GEM_SOURCES=
  tmp_sources=false
  for i in $@; do
    if [[ "${tmp_sources}" == "true" ]]; then
      GEM_SOURCES="${i}"
      break
      tmp_sources=false
    fi
    if [[ "${i}" == "--gemsources" ]]; then
      tmp_sources=true
    fi
  done

  if [[ ! -z "${GEM_SOURCES}" ]]; then
    echo "Re-configuring gem sources"
    # Remove the old sources
    OLD_GEM_SOURCES=$(gem sources --list | tail -n+3 | tr '\n' ' ')
    for i in $OLD_GEM_SOURCES; do
      gem sources -r "$i"
    done

    # Add the replacement sources
    OIFS=$IFS && IFS=','
    for i in $GEM_SOURCES; do
      MAX_RETRIES=5
      export attempts=1
      exit_code=1
      while [[ $exit_code -ne 0 ]] && [[ $attempts -le ${MAX_RETRIES} ]]; do
        gem sources -a $i
        exit_code=$?
        if [[ $exit_code -ne 0 ]]; then
          sleep_time=$((attempts * 10))
          echo Sleeping for ${sleep_time}s before retrying ${attempts}/${MAX_RETRIES}
          sleep ${sleep_time}s
          attempts=$((attempts + 1))
        fi
      done
    done
    IFS=$OIFS
  fi
}

# Install the yum dependencies
install_yum_deps() {
  echo "Installing required yum packages"
  yum_install augeas-devel ncurses-devel gcc gcc-c++ curl git redhat-lsb-core
}

# Install the gem dependencies
install_gem_deps() {
  echo "Installing required gems"
  gem_install puppet:3.7.4 hiera facter ruby-augeas hiera-eyaml ruby-shadow
}

# Inject the SSH key to allow git cloning
inject_ssh_key() {
  # Set Git login params
  echo "Injecting private ssh key"
  GITHUB_PRI_KEY=$(cat "${FACTER_init_repoprivkeyfile}")
  if [[ ! -d /root/.ssh ]]; then
    mkdir /root/.ssh
    chmod 600 /root/.ssh
  fi
  echo "${GITHUB_PRI_KEY}" > /root/.ssh/id_rsa
  echo "StrictHostKeyChecking=no" > /root/.ssh/config
  chmod -R 600 /root/.ssh
}

# Clone the git repo
clone_git_repo() {
  # Clone private repo.
  echo "Cloning ${FACTER_init_repouser}/${FACTER_init_reponame} repo"
  rm -rf "${FACTER_init_repodir}"
  git clone -b "${FACTER_init_repobranch}" git@github.com:"${FACTER_init_repouser}"/"${FACTER_init_reponame}".git "${FACTER_init_repodir}"
  # Exit if the clone fails
  if [[ ! -d "${FACTER_init_repodir}" ]]; then
    echo "Failed to clone git@github.com:${FACTER_init_repouser}/${FACTER_init_reponame}.git" && exit 1
  fi
}

# Symlink the cloned git repo to the usual location for Puppet to run
symlink_puppet_dir() {
  # Link /etc/puppet to our private repo.
  PUPPET_DIR="${FACTER_init_repodir}/puppet"
  rm -rf /etc/puppet > /dev/null 2>&1
  rm /etc/hiera.yaml > /dev/null 2>&1
  ln -s "${PUPPET_DIR}" /etc/puppet
  ln -s /etc/puppet/hiera.yaml /etc/hiera.yaml
}

# Inject the eyaml keys
inject_eyaml_keys() {
  # If no eyaml keys have been provided, create some
  if [[ -z "${FACTER_init_eyamlpubkeyfile}" ]] && [[ -z "${FACTER_init_eyamlprivkeyfile}" ]] && [[ ! -d "/etc/puppet/secure/keys" ]]; then
    if [[ ! -d /etc/puppet/secure/keys ]]; then
      mkdir -p /etc/puppet/secure/keys
      chmod -R 500 /etc/puppet/secure
    fi
    cd /etc/puppet/secure || exit
    echo -n "Creating eyaml key pair"
    eyaml createkeys
  else
  # Or use the ones provided
    echo "Injecting eyaml keys"
    EYAML_PUB_KEY=$(cat "${FACTER_init_eyamlpubkeyfile}")
    EYAML_PRI_KEY=$(cat "${FACTER_init_eyamlprivkeyfile}")
    mkdir -p /etc/puppet/secure/keys
    echo "${EYAML_PUB_KEY}" > /etc/puppet/secure/keys/public_key.pkcs7.pem
    echo "${EYAML_PRI_KEY}" > /etc/puppet/secure/keys/private_key.pkcs7.pem
    chmod -R 500 /etc/puppet/secure
    chmod 400 /etc/puppet/secure/keys/*.pem
  fi
}

run_librarian() {
  echo -n "Installing activesupport:4.2.6"
  gem install activesupport:4.2.6 --no-ri --no-rdoc
  echo -n "Installing librarian-puppet"
  gem install librarian-puppet --no-ri --no-rdoc
  echo -n "Installing Puppet modules"
  librarian-puppet install --verbose
  librarian-puppet show
}

# Fetch the Puppet modules via the moduleshttpcache or librarian-puppet
fetch_puppet_modules() {
  ENV_BASE_PUPPETFILE="${FACTER_init_env}/Puppetfile.base"
  ENV_ROLE_PUPPETFILE="${FACTER_init_env}/Puppetfile.${FACTER_init_role}"
  BASE_PUPPETFILE=Puppetfile.base
  ROLE_PUPPETFILE=Puppetfile."${FACTER_init_role}"
  if [[ -f "/etc/puppet/Puppetfiles/${ENV_BASE_PUPPETFILE}" ]]; then
    BASE_PUPPETFILE="${ENV_BASE_PUPPETFILE}"
  fi
  if [[ -f "/etc/puppet/Puppetfiles/${ENV_ROLE_PUPPETFILE}" ]]; then
    ROLE_PUPPETFILE="${ENV_ROLE_PUPPETFILE}"
  fi
  PUPPETFILE=/etc/puppet/Puppetfile
  rm -f "${PUPPETFILE}" ; cat /etc/puppet/Puppetfiles/"${BASE_PUPPETFILE}" /etc/puppet/Puppetfiles/"${ROLE_PUPPETFILE}" > "${PUPPETFILE}"


  PUPPETFILE_MD5SUM=$(md5sum "${PUPPETFILE}" | cut -d " " -f 1)
  if [[ ! -z $PASSWD ]]; then
    MODULE_ARCH=${FACTER_init_role}."${PUPPETFILE_MD5SUM}".tar.gz.aes
  else
    MODULE_ARCH=${FACTER_init_role}."${PUPPETFILE_MD5SUM}".tar.gz
  fi

  cd "${PUPPET_DIR}" || exit

  if [[ ! -z "${FACTER_init_moduleshttpcache}" && "200" == $(curl "${FACTER_init_moduleshttpcache}"/"${MODULE_ARCH}"  --head --silent | head -n 1 | cut -d ' ' -f 2) ]]; then
    echo -n "Downloading pre-packed Puppet modules from cache..."
    if [[ ! -z $PASSWD ]]; then
      echo "================="
      echo "Using Encrypted modules ${FACTER_init_moduleshttpcache}/$MODULE_ARCH "
      echo "================="
      curl --silent -o modules.tar.gz.aes ${FACTER_init_moduleshttpcache}/$MODULE_ARCH
      openssl enc -base64 -aes-128-cbc -d -salt -in modules.tar.gz.aes -out modules.tar.gz -k $PASSWD
    else
      curl --silent -o modules.tar.gz ${FACTER_init_moduleshttpcache}/$MODULE_ARCH
    fi


    tar tf modules.tar.gz &> /dev/null
    TEST_TAR=$?
    if [[ $TEST_TAR -eq 0 ]]; then
      tar zxpf modules.tar.gz
      echo "================="
      echo "Unpacked modules:"
      find ./modules -maxdepth 1 -type d | cut -d '/' -f 3
      echo "================="
    else
      echo "Seems we failed to decrypt archive file... running librarian-puppet instead"
      run_librarian
    fi

  else
    run_librarian
  fi
}

# Execute the Puppet run
run_puppet() {
  export LC_ALL=en_GB.utf8
  echo ""
  echo "Running puppet apply"
  puppet apply /etc/puppet/manifests/site.pp --detailed-exitcodes
  PUPPET_EXIT=$?

  if [ $PUPPET_EXIT == 2 ]; then
    PUPPET_EXIT=0
  fi

  echo ""
  echo "Top 10 slowest Puppet resources"
  echo "==============================="
  PERFORMANCE_DATA=( $(grep evaluation_time /var/lib/puppet/reports/*/*.yaml | awk '{print $3}' | sort -n | tail -10 ) )
  for i in ${PERFORMANCE_DATA[*]}; do
    echo -n "${i}s - "
    echo "$(grep -B 3 "$i" /var/lib/puppet/reports/*/*.yaml | head -1 | awk '{print $2 $3}' )"
  done | tac

  exit $PUPPET_EXIT
}

main "$@"
