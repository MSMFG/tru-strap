#!/bin/bash
# Tru-Strap: prepare an instance for a Puppet run

main() {
    parse_args "$@"
    set_gemsources "$@"
    inject_ssh_key
    inject_repo_token
    clone_git_repo
    symlink_puppet_dir
    inject_eyaml_keys
    fetch_puppet_modules
    set_aws_region
    run_puppet
    secure_puppet_folder
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
  [--securepuppet|-z] \n \
  [--help|-h] \n \
  [--debug] \n \
  [--puppet-opts] \n \
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
      --repourl|-s)
        set_facter init_repourl "${2}"
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
      --securepuppet|-z)
        SECURE_PUPPET="${2}"
        shift
        ;;
      --puppet-opts)
        PUPPET_APPLY_OPTS="${2}"
        shift
        ;;
      --ruby-required-version)
        echo "--ruby-required-version is now deprecated in tru-strap. Update msm-packer-templates" >&2
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
  [[ -z "${FACTER_init_repourl}" ]] && set_facter init_repourl "git@github.com:"
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

# Set custom gem sources
# Only for Rightform-CI now
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
  if ! git clone --depth=1 -b "${FACTER_init_repobranch}" "${FACTER_init_repourl}${FACTER_init_repouser}"/"${FACTER_init_reponame}".git "${FACTER_init_repodir}";
  then
    log_error "Failed to clone ${FACTER_init_repourl}${FACTER_init_repouser}/${FACTER_init_reponame}.git"
  fi
}

# Symlink the cloned git repo to the usual location for Puppet to run
symlink_puppet_dir() {
  local RESULT=''
  # Link /etc/puppet to our private repo.
  PUPPET_DIR="${FACTER_init_repodir}/puppet"
  if [ -e /etc/puppet ]; then
    RESULT=$(rm -rf /etc/puppet);
    if [[ $? != 0 ]]; then
      log_error "Failed to remove /etc/puppet\nrm returned:\n${RESULT}"
    fi
  fi

  RESULT=$(ln -s "${PUPPET_DIR}" /etc/puppet)
  if [[ $? != 0 ]]; then
    log_error "Failed to create symlink from ${PUPPET_DIR}\nln returned:\n${RESULT}"
  fi

  if [ -e /etc/hiera.yaml ]; then
    RESULT=$(rm -f /etc/hiera.yaml)
    if [[ $? != 0 ]]; then
      log_error "Failed to remove /etc/hiera.yaml\nrm returned:\n${RESULT}"
    fi
  fi

  RESULT=$(ln -s /etc/puppet/hiera.yaml /etc/hiera.yaml)
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
    mkdir -p /etc/puppet/secure/keys || log_error "Failed to create /etc/puppet/secure/keys"
    chmod -R 550 /etc/puppet/secure || log_error "Failed to change permissions on /etc/puppet/secure"
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

  # Override ./Puppetfile.base with $ENV/Puppetfile.base if one exists.
  if [[ -f "/etc/puppet/Puppetfiles/${ENV_BASE_PUPPETFILE}" ]]; then
    BASE_PUPPETFILE="${ENV_BASE_PUPPETFILE}"
  fi
  # Override Puppetfile.$ROLE with $ENV/Puppetfile.$ROLE if one exists.
  if [[ -f "/etc/puppet/Puppetfiles/${ENV_ROLE_PUPPETFILE}" ]]; then
    ROLE_PUPPETFILE="${ENV_ROLE_PUPPETFILE}"
  fi

  # Concatenate base, and role specific puppetfiles to produce final module list.
  PUPPETFILE=/etc/puppet/Puppetfile
  rm -f "${PUPPETFILE}" ; cat /etc/puppet/Puppetfiles/"${BASE_PUPPETFILE}" > "${PUPPETFILE}"
  echo "" >> "${PUPPETFILE}"
  cat /etc/puppet/Puppetfiles/"${ROLE_PUPPETFILE}" >> "${PUPPETFILE}"

  PUPPETFILE_MD5SUM=$(md5sum "${PUPPETFILE}" | cut -d " " -f 1)
  if [[ ! -z $PASSWD ]]; then
    MODULE_ARCH=${FACTER_init_role}."${PUPPETFILE_MD5SUM}".tar.aes.gz
  else
    MODULE_ARCH=${FACTER_init_role}."${PUPPETFILE_MD5SUM}".tar.gz
  fi
  echo "Cached puppet module tar ball should be ${MODULE_ARCH}, checking if it exists"
  cd "${PUPPET_DIR}" || log_error "Failed to cd to ${PUPPET_DIR}"

  # check if the moduleshttpcache fact exists
  if [[ ! -z "${FACTER_init_moduleshttpcache}" ]]; then
  
    # check if its an s3 address
    if [[ "${FACTER_init_moduleshttpcache}" =~ "s3-eu-west-1" ]]; then

      # if its s3 address update url from https://s3 to s3://
      if [[ "${FACTER_init_moduleshttpcache}" =~ "v2" ]]; then
        FACTER_init_moduleshttpcache="s3://$(echo $FACTER_init_moduleshttpcache | cut -d: -f2 | cut -d/ -f4-)"
      fi

      # check if the module is in the bucket. If run for the first time it wont be.
      if [[ $(/bin/aws s3 ls ${FACTER_init_moduleshttpcache}/${MODULE_ARCH} | wc -l) -ge 1 ]]; then

        echo -n "Downloading pre-packed Puppet modules ${FACTER_init_moduleshttpcache}..."
        /bin/aws s3 cp ${FACTER_init_moduleshttpcache}/${MODULE_ARCH} ${MODULE_ARCH}

        tar tf ${MODULE_ARCH} &> /dev/null
        tar_test=$?

        if [[ $tar_test -eq 0 ]]; then
          tar xpf ${MODULE_ARCH}
          echo "=================="
          echo "Unpacking modules:"
          puppet module list
          echo "=================="
        else 
          echo "There seems to be a problem with ${MODULE_ARCH}. Running librarian-puppet instead"
          run_librarian
        fi
      else
        echo "Module isnt in ${FACTER_init_moduleshttpcache}/${MODULE_ARCH} running librarian"
        run_librarian
      fi

    elif [[ "200" == $(curl "${FACTER_init_moduleshttpcache}"/"${MODULE_ARCH}"  --head --silent | head -n 1 | cut -d ' ' -f 2) ]]; then
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
        puppet module list --color false
        echo "================="
      else
        echo "Seems we failed to decrypt archive file... running librarian-puppet instead"
        run_librarian
      fi
    fi
  else
    echo "Nope!"
    run_librarian
  fi
}

# Set AWS_REGION prior to puppet run
set_aws_region() {
  export AWS_REGION=`curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone | sed 's/[a-z]$//'`
}

# Execute the Puppet run
run_puppet() {
  export LC_ALL=en_GB.utf8
  echo ""
  echo "Running puppet apply"
  export FACTERLIB="${FACTERLIB}:$(ipaddress_primary_path)"
  puppet apply ${PUPPET_APPLY_OPTS} /etc/puppet/manifests/site.pp --detailed-exitcodes --color false

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
  PUPPET_LOG=$(find /var/lib/puppet/reports -type f -exec ls -ltr {} + | tail -n 1 | awk '{print $9}')
  PERFORMANCE_DATA=( $(grep evaluation_time "${PUPPET_LOG}" | awk '{print $2}' | sort -n | tail -10 ) )
  echo "===============-Top 10 slowest Puppet resources-==============="
  for i in ${PERFORMANCE_DATA[*]}; do
    echo -n "${i}s - "
    echo "$(grep -B 3 "evaluation_time: $i" /var/lib/puppet/reports/*/*.yaml | head -1 | awk '{$1="";print}' )"
  done | tac
  echo "===============-Top 10 slowest Puppet resources-==============="
}

secure_puppet_folder()  {
  local RESULT=''
  if [[ ! -z "${SECURE_PUPPET}" && "${SECURE_PUPPET}" == "true" && -d ${FACTER_init_repodir}/puppet ]]; then
    echo "secure_puppet_folder : chmod -R 700 ${FACTER_init_repodir}/puppet directory"
    RESULT=$(chmod -R 700 ${FACTER_init_repodir}/puppet)
    if [[ $? != 0 ]]; then
      log_error "Failed to set permissions on ${FACTER_init_repodir}/puppet:\n${RESULT}"
    fi
  fi
}

main "$@"
