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
    inject_repo_token
    clone_git_repo
    symlink_puppet_dir
    inject_eyaml_keys
    fetch_puppet_modules
    run_puppet
}

usagemessage="Error, USAGE: $(basename "${0}") \n \
  --role|-r \n \
  --environment|-e \n \
  --repouser|-u \n \
  --reponame|-n \n \
  --repoprivkeyfile|-k \n \
  [--repotoken|-t] \n \
  [--repobranch|-b] \n \
  [--repodir|-d] \n \
  [--eyamlpubkeyfile|-j] \n \
  [--eyamlprivkeyfile|-m] \n \
  [--gemsources|-s] \n \
  [--help|-h] \n \
  [--version|-v]"

function log_error() {
    echo "###############------Fatal error!------###############"
    caller
    printf "%s\n" "${1}"
    exit 1
}

# Parse the commmand line arguments
parse_args() {
  while [[ -n "${1}" ]] ; do
    case "${1}" in
      --help|-h)
        echo -e ${usagemessage}
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
        set_facter init_repoprivkeyfile "${2}"
        shift
        ;;
      --repotoken|-t)
        set_facter init_repotoken "${2}"
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
        set_facter init_eyamlpubkeyfile "${2}"
        shift
        ;;
      --eyamlprivkeyfile|-m)
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
      --gemsources)
        shift
        ;;
      --debug)
        shift
        ;;
      *)
        echo "Unknown argument: ${1}"
        echo -e "${usagemessage}"
        exit 1
        ;;
    esac
    shift
  done

  # Define required parameters.
  if [[ -z "${FACTER_init_role}" || \
        -z "${FACTER_init_env}"  || \
        -z "${FACTER_init_repouser}" || \
        -z "${FACTER_init_reponame}" || \
        -z "${FACTER_init_repoprivkeyfile}" ]]; then
    echo -e "${usagemessage}"
    exit 1
  fi

  # Set some defaults if they aren't given on the command line.
  [[ -z "${FACTER_init_repobranch}" ]] && set_facter init_repobranch master
  [[ -z "${FACTER_init_repodir}" ]] && set_facter init_repodir /opt/"${FACTER_init_reponame}"
}

# Install yum packages if they're not already installed
yum_install() {
  for i in "$@"
  do
    if ! rpm -q ${i} > /dev/null 2>&1; then
      local RESULT=''
      RESULT=$(yum install -y ${i} 2>&1)
      if [[ $? != 0 ]]; then
        log_error "Failed to install yum package: ${i}\nyum returned:\n${RESULT}"
      else
        echo "Installed yum package: ${i}"
      fi
    fi
  done
}

# Install Ruby gems if they're not already installed
gem_install() {
  local RESULT=''
  for i in "$@"
  do
    if [[ ${i} =~ ^.*:.*$ ]];then
      MODULE=$(echo ${i} | cut -d ':' -f 1)
      VERSION=$(echo ${i} | cut -d ':' -f 2)
      if ! gem list -i --local ${MODULE} --version ${VERSION} > /dev/null 2>&1; then
        echo "Installing ${i}"
        RESULT=$(gem install ${i} --no-ri --no-rdoc)
        if [[ $? != 0 ]]; then
          log_error "Failed to install gem: ${i}\ngem returned:\n${RESULT}"
        fi
      fi
    else
      if ! gem list -i --local ${i} > /dev/null 2>&1; then
        echo "Installing ${i}"
        RESULT=$(gem install ${i} --no-ri --no-rdoc)
        if [[ $? != 0 ]]; then
          log_error "Failed to install gem: ${i}\ngem returned:\n${RESULT}"
        fi
      fi
    fi
  done
}

print_version() {
  echo "${1}" "${2}"
}

# Set custom facter facts
set_facter() {
  local key=${1}
  #Note: The name of the evironment variable is not the same as the facter fact.
  local export_key=FACTER_${key}
  local value=${2}
  export ${export_key}="${value}"
  if [[ ! -d /etc/facter ]]; then
    mkdir -p /etc/facter/facts.d || log_error "Failed to create /etc/facter/facts.d"
  fi
  if ! echo "${key}=${value}" > /etc/facter/facts.d/"${key}".txt; then
    log_error "Failed to create /etc/facter/facts.d/${key}.txt"
  fi
  chmod -R 600 /etc/facter || log_error "Failed to set permissions on /etc/facter"
  cat /etc/facter/facts.d/"${key}".txt || log_error "Failed to create ${key}.txt"
}

setup_rhel7_repo() {
  yum_install redhat-lsb-core
  dist=$(lsb_release -is)
  majorversion=$(lsb_release -rs | cut -f1 -d.)
  if [[ "$majorversion" == "7" ]] && [[ "$dist" == "RedHatEnterpriseServer" ]]; then
    echo "RedHat Enterprise version 7- adding extra repo for *-devel"
    yum_install yum-utils
    yum-config-manager --enable rhui-REGION-rhel-server-optional || log_error "Failed to run yum-config-manager"
  fi

}

install_ruby() {
  majorversion=$(lsb_release -rs | cut -f1 -d.)
  ruby_v="2.1.5"
  ruby -v  > /dev/null 2>&1
  if [[ $? -ne 0 ]] || [[ $(ruby -v | awk '{print $2}' | cut -d 'p' -f 1) != $ruby_v ]]; then
    yum remove -y ruby-* || log_error "Failed to remove old ruby"
    yum_install https://s3-eu-west-1.amazonaws.com/msm-public-repo/ruby/ruby-2.1.5-2.el${majorversion}.x86_64.rpm
  fi
}

# Set custom gem sources
set_gemsources() {
  GEM_SOURCES=
  tmp_sources=false
  for i in "$@"; do
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
      gem sources -r "$i" || log_error "Failed to remove gem source ${i}"
    done

    # Add the replacement sources
    local NO_SUCCESS=1
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
        else
          NO_SUCCESS=0
        fi
      done
    done
    IFS=$OIFS
    if [[ $NO_SUCCESS == 1 ]]; then
      log_error "All gem sources failed to add"
    fi
  fi
}

# Install the yum dependencies
install_yum_deps() {
  echo "Installing required yum packages"
  yum_install augeas-devel ncurses-devel gcc gcc-c++ curl git redhat-lsb-core
}

# Install the gem dependencies
install_gem_deps() {
  echo "Installing puppet and related gems"
  gem_install puppet:4.8.2 hiera facter ruby-augeas hiera-eyaml ruby-shadow
}

# Inject the SSH key to allow git cloning
inject_ssh_key() {
  # Set Git login params
  echo "Injecting private ssh key"
  GITHUB_PRI_KEY=$(cat "${FACTER_init_repoprivkeyfile}")
  if [[ ! -d /root/.ssh ]]; then
    mkdir /root/.ssh || log_error "Failed to create /root/.ssh"
    chmod 600 /root/.ssh || log_error "Failed to change permissions on /root/.ssh"
  fi
  echo "${GITHUB_PRI_KEY}" > /root/.ssh/id_rsa || log_error "Failed to set ssh private key"
  echo "StrictHostKeyChecking=no" > /root/.ssh/config ||log_error "Failed to set ssh config"
  chmod -R 600 /root/.ssh || log_error "Failed to set permissions on /root/.ssh"
}

# Inject the Git token to allow git cloning
inject_repo_token() {
  echo "Injecting github access token"
  if [[ ! -z ${FACTER_init_repotoken} ]]; then
    echo "${FACTER_init_repotoken}" >> /root/.git-credentials || log_error "Failed to add access token"
    chmod 600 /root/.git-credentials || log_error "Failed to set permissions on /root/.git-credentials"
    git config --global credential.helper store || log_error "Failed to set git config"
  fi
}

# Clone the git repo
clone_git_repo() {
  # Clone private repo.
  echo "Cloning ${FACTER_init_repouser}/${FACTER_init_reponame} repo"
  rm -rf "${FACTER_init_repodir}"
  # Exit if the clone fails
  if ! git clone --depth=1 -b "${FACTER_init_repobranch}" git@github.com:"${FACTER_init_repouser}"/"${FACTER_init_reponame}".git "${FACTER_init_repodir}";
  then
    log_error "Failed to clone git@github.com:${FACTER_init_repouser}/${FACTER_init_reponame}.git"
  fi
}

# Symlink the cloned git repo to the usual location for Puppet to run
# Puppet 4 directories
# mkdir /etc/puppetlabs
# ln -s /opt/dwh-role-configs/puppet /etc/puppetlabs/puppet
# mkdir /etc/puppetlabs/code
# ln -s /opt/dwh-role-configs/puppet/modules /etc/puppetlabs/code/modules
symlink_puppet_dir() {
  local RESULT=''
  # Link /etc/puppetlabs/puppet to our private repo.
  PUPPET_DIR="${FACTER_init_repodir}/puppet"
  # new modules location for puppet 4
  mkdir -p /etc/puppetlabs/code
  mkdir -p /etc/puppet

  if [ -e /etc/puppetlabs/puppet ]; then
    RESULT=$(rm -rf /etc/puppetlabs/puppet);
    if [[ $? != 0 ]]; then
      log_error "Failed to remove /etc/puppetlabs/puppet\nrm returned:\n${RESULT}"
    fi
  fi

  RESULT=$(ln -s "${PUPPET_DIR}" /etc/puppetlabs/puppet)
  if [[ $? != 0 ]]; then
    log_error "Failed to create symlink from ${PUPPET_DIR}\nln returned:\n${RESULT}"
  fi

  RESULT=$(ln -s /etc/puppetlabs/puppet/modules /etc/puppetlabs/code/modules)
  if [[ $? != 0 ]]; then
    log_error "Failed to create symlink from ${PUPPET_DIR}/modules\nln returned:\n${RESULT}"
  fi

  RESULT=$(ln -s /etc/puppetlabs/puppet/hieradata /etc/puppet/hieradata)
  if [[ $? != 0 ]]; then
    log_error "Failed to create symlink from ${PUPPET_DIR}/hieradata\nln returned:\n${RESULT}"
  fi

  if [ -e /etc/hiera.yaml ]; then
    RESULT=$(rm -f /etc/hiera.yaml)
    if [[ $? != 0 ]]; then
      log_error "Failed to remove /etc/hiera.yaml\nrm returned:\n${RESULT}"
    fi
  fi

  RESULT=$(ln -s /etc/puppetlabs/puppet/hiera.yaml /etc/hiera.yaml)
  if [[ $? != 0 ]]; then
    log_error "Failed to create symlink from /etc/hiera.yaml\nln returned:\n${RESULT}"
  fi
}

# Inject the eyaml keys
inject_eyaml_keys() {

  # create secure group
  GRP='secure'
  getent group $GRP
  ret=$?
  case $ret in
    0) echo "group $GRP exists" ;;
    2) ( groupadd $GRP && echo "added group $GRP" ) || log_error "Failed to create group $GRP" ;;
    *) log_error "Exit code $ret : Failed to verify group $GRP" ;;
  esac

  if [[ ! -d /etc/puppet/secure/keys ]]; then
    mkdir -p /etc/puppet/secure/keys || log_error "Failed to create /etc/puppetlabs/puppet/secure/keys"
    chmod -R 550 /etc/puppet/secure || log_error "Failed to change permissions on /etc/puppetlabs/puppet/secure"
  fi
  # If no eyaml keys have been provided, create some
  if [[ -z "${FACTER_init_eyamlpubkeyfile}" ]] && [[ -z "${FACTER_init_eyamlprivkeyfile}" ]]; then
    cd /etc/puppet/secure || log_error "Failed to cd to /etc/puppet/secure"
    echo -n "Creating eyaml key pair"
    eyaml createkeys || log_error "Failed to create eyaml keys."
  else
  # Or use the ones provided
    echo "Injecting eyaml keys"
    local RESULT=''

    RESULT=$(cp ${FACTER_init_eyamlpubkeyfile} /etc/puppet/secure/keys/public_key.pkcs7.pem)
    if [[ $? != 0 ]]; then
      log_error "Failed to insert public key:\n${RESULT}"
    fi

    RESULT=$(cp ${FACTER_init_eyamlprivkeyfile} /etc/puppet/secure/keys/private_key.pkcs7.pem)
    if [[ $? != 0 ]]; then
      log_error "Failed to insert private key:\n${RESULT}"
    fi

    chgrp -R $GRP /etc/puppet/secure || log_error "Failed to change group on /etc/puppet/secure"
    chmod 440 /etc/puppet/secure/keys/*.pem || log_error "Failed to set permissions on /etc/puppet/secure/keys/*.pem"
  fi
}

run_librarian() {
  gem_install activesupport:4.2.6 librarian-puppet
  echo -n "Running librarian-puppet"
  local RESULT=''
  RESULT=$(librarian-puppet install --verbose)
  if [[ $? != 0 ]]; then
    log_error "librarian-puppet failed.\nThe full output was:\n${RESULT}"
  fi
  librarian-puppet show
}

# Fetch the Puppet modules via the moduleshttpcache or librarian-puppet
fetch_puppet_modules() {
  ENV_BASE_PUPPETFILE="${FACTER_init_env}/Puppetfile.base"
  ENV_ROLE_PUPPETFILE="${FACTER_init_env}/Puppetfile.${FACTER_init_role}"
  BASE_PUPPETFILE=Puppetfile.base
  ROLE_PUPPETFILE=Puppetfile."${FACTER_init_role}"
  if [[ -f "/etc/puppetlabs/puppet/Puppetfiles/${ENV_BASE_PUPPETFILE}" ]]; then
    BASE_PUPPETFILE="${ENV_BASE_PUPPETFILE}"
  fi
  if [[ -f "/etc/puppetlabs/puppet/Puppetfiles/${ENV_ROLE_PUPPETFILE}" ]]; then
    ROLE_PUPPETFILE="${ENV_ROLE_PUPPETFILE}"
  fi
  PUPPETFILE=/etc/puppetlabs/puppet/Puppetfile
  rm -f "${PUPPETFILE}" ; cat /etc/puppetlabs/puppet/Puppetfiles/"${BASE_PUPPETFILE}" > "${PUPPETFILE}"
  echo "" >> "${PUPPETFILE}"
  cat /etc/puppetlabs/puppet/Puppetfiles/"${ROLE_PUPPETFILE}" >> "${PUPPETFILE}"


  PUPPETFILE_MD5SUM=$(md5sum "${PUPPETFILE}" | cut -d " " -f 1)
  if [[ ! -z $PASSWD ]]; then
    MODULE_ARCH=${FACTER_init_role}."${PUPPETFILE_MD5SUM}".tar.aes.gz
  else
    MODULE_ARCH=${FACTER_init_role}."${PUPPETFILE_MD5SUM}".tar.gz
  fi

  cd "${PUPPET_DIR}" || log_error "Failed to cd to ${PUPPET_DIR}"

  if [[ ! -z "${FACTER_init_moduleshttpcache}" && "200" == $(curl "${FACTER_init_moduleshttpcache}"/"${MODULE_ARCH}"  --head --silent | head -n 1 | cut -d ' ' -f 2) ]]; then
    echo -n "Downloading pre-packed Puppet modules from cache..."
    if [[ ! -z $PASSWD ]]; then
      package=modules.tar
      echo "================="
      echo "Using Encrypted modules ${FACTER_init_moduleshttpcache}/$MODULE_ARCH "
      echo "================="
      curl --silent ${FACTER_init_moduleshttpcache}/$MODULE_ARCH |
        gzip -cd |
        openssl enc -base64 -aes-128-cbc -d -salt -out $package -k $PASSWD
    else
      package=modules.tar.gz
      curl --silent -o $package ${FACTER_init_moduleshttpcache}/$MODULE_ARCH
    fi


    tar tf $package &> /dev/null
    TEST_TAR=$?
    if [[ $TEST_TAR -eq 0 ]]; then
      tar xpf $package
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
  puppet apply /etc/puppetlabs/puppet/manifests/site.pp --detailed-exitcodes

  PUPPET_EXIT=$?

  case $PUPPET_EXIT in
    0 )
      echo "Puppet run succeeded with no failures."
      ;;
    1 )
      log_error "Puppet run failed."
      ;;
    2 )
      echo "Puppet run succeeded, and some resources were changed."
      ;;
    4 )
      log_error "Puppet run succeeded, but some resources failed."
      ;;
    6 )
      log_error "Puppet run succeeded, and included both changes and failures."
      ;;
    * )
      log_error "Puppet run returned unexpected exit code."
      ;;
  esac

  #Find the newest puppet log
  local PUPPET_LOG=''
  PUPPET_LOG=$(find /opt/puppetlabs/puppet/cache/reports -type f -exec ls -ltr {} + | tail -n 1 | awk '{print $9}')
  PERFORMANCE_DATA=( $(grep evaluation_time "${PUPPET_LOG}" | awk '{print $2}' | sort -n | tail -10 ) )
  echo "===============-Top 10 slowest Puppet resources-==============="
  for i in ${PERFORMANCE_DATA[*]}; do
    echo -n "${i}s - "
    echo "$(grep -B 3 "$i" /var/lib/puppet/reports/*/*.yaml | head -1 | awk '{print $2 $3}' )"
  done | tac
  echo "===============-Top 10 slowest Puppet resources-==============="
}

main "$@"
