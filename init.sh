#!/bin/bash
# Tru-Strap: prepare an instance for a Puppet run

main() {
    parse_args "$@"
    prepend_nameserver_for_skydns
    setup_rhel7_repo
    upgrade_nss
    install_yum_deps
    install_ruby
    set_gemsources "$@"
    configure_global_gemrc
    install_gem_deps
    patch_puppet
    inject_ssh_key
    inject_repo_token
    clone_git_repo
    symlink_puppet_dir
    inject_eyaml_keys
    fetch_puppet_modules
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
        RUBY_REQUIRED_VERSION="${2}"
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

# For the role skydns, prepend the nameserver to the list returned by DHCP
prepend_nameserver_for_skydns() {
  if [[ $FACTER_init_role == "skydns" ]]; then
    echo "Prepending dhclient domain-name-server..."
    MAC_ADDR=$(cat /sys/class/net/eth0/address)
    VPC_CIDR=$(curl --silent 169.254.169.254/latest/meta-data/network/interfaces/macs/${MAC_ADDR}/vpc-ipv4-cidr-block)
    VPC_IP=$(echo $VPC_CIDR | cut -d'/' -f1)
    AWS_DNS_IP=$(echo $VPC_IP | sed -e "s/\([0-9]\+\)\.\([0-9]\+\)\.\([0-9]\+\)\..\+/\1.\2.\3.2/gi")
    DHCLIENT_OPTION="prepend domain-name-servers $AWS_DNS_IP;"
    echo "    $DHCLIENT_OPTION"
    grep "$DHCLIENT_OPTION" /etc/dhcp/dhclient.conf 1>/dev/null || echo $DHCLIENT_OPTION >> /etc/dhcp/dhclient.conf
    dhclient -r && dhclient || echo "Could not renew DHCP lease. Continuing..."
  fi
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

upgrade_nss() {
  yum_install redhat-lsb-core
  majorversion=$(lsb_release -rs | cut -f1 -d.)
  if [[ "$majorversion" == "6" ]]; then
    echo "Version 6 - Upgrading NSS package TLS1.2 cloning from GitHub.com"
    yum upgrade -y nss 2>&1 || log_error "Failed to upgrade nss package"
  fi
}

install_ruby() {
  if [[ -z "${RUBY_REQUIRED_VERSION}" ]]; then
    RUBY_REQUIRED_VERSION=2.1.5:2.1.5-2
  fi
  ruby_v=$(echo ${RUBY_REQUIRED_VERSION} | cut -d: -f1)
  ruby_p_v=$(echo ${RUBY_REQUIRED_VERSION} | cut -d: -f2)
  majorversion=$(lsb_release -rs | cut -f1 -d.)
  ruby -v  > /dev/null 2>&1
  if [[ $? -ne 0 ]] || [[ $(ruby -e 'puts RUBY_VERSION') != $ruby_v ]]; then
    yum remove -y ruby-* || log_error "Failed to remove old ruby"
    yum_install https://s3-eu-west-1.amazonaws.com/msm-public-repo/ruby/ruby-${ruby_p_v}.el${majorversion}.x86_64.rpm
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
  gem_install unversioned_gem_manifest:1.0.0
  # Default in /tmp may be unreadable for systems that overmount /tmp (AEM)
  export RUBYGEMS_UNVERSIONED_MANIFEST=/var/log/unversioned_gems.yaml  
  gem_install puppet:3.8.7 hiera facter 'ruby-augeas:~>0.5' 'hiera-eyaml:~>2.1' 'ruby-shadow:~>2.5' facter_ipaddress_primary:1.1.0
  # Configure facter_ipaddress_primary so it works outside this script.
  # i.e Users logging in interactively can run puppet apply successfully
  echo 'export FACTERLIB="${FACTERLIB}:$(ipaddress_primary_path)"'>/etc/profile.d/ipaddress_primary.sh
  chmod 0755 /etc/profile.d/ipaddress_primary.sh
}

# Only happens for Rubies >= 2.2
patch_puppet() {
  /usr/bin/env ruby <<-EORUBY
# If for some reason run with old Rubies
class Array
  include Comparable
end
exit if RUBY_VERSION.split('.').map(&:to_i) < [2, 2]
require 'rubygems'
# Locate main puppet library inside gems
puppet = Gem.find_files('puppet.rb').find { |path| path.include?('3.8.7') }
exit unless puppet
vendor_path = File.expand_path('../puppet/vendor', puppet)
require 'fileutils'
Dir.chdir(vendor_path) do
  exit unless File.exist?('load_safe_yaml.rb')
  FileUtils.mv('load_safe_yaml.rb', '_load_safe_yaml.rb')
  FileUtils.mv('require_vendored.rb', '_require_vendored.rb')
  File.write('require_vendored.rb', 'module SafeYAML; OPTIONS = {}; end')
end
puts "Puppet installation patched for Ruby #{RUBY_VERSION} (by tru-strap)"
EORUBY
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
  gem_install activesupport:4.2.6 librarian-puppet:3.0.0
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
      puppet module list --color false
      echo "================="
    else
      echo "Seems we failed to decrypt archive file... running librarian-puppet instead"
      run_librarian
    fi

  else
    echo "Nope!"
    run_librarian
  fi
}

# Move root's .gemrc to global location (/etc/gemrc) to standardise all gem environment sources
configure_global_gemrc() {
  if [ -f /root/.gemrc ]; then
    echo "Moving root's .gemrc to global location (/etc/gemrc)"
    mv /root/.gemrc /etc/gemrc
  else
    echo "  Warning: /root/.gemrc did not exist!"
  fi
}

# Execute the Puppet run
run_puppet() {
  export LC_ALL=en_GB.utf8
  echo ""
  echo "Running puppet apply"
  export FACTERLIB="${FACTERLIB}:$(ipaddress_primary_path)"
  puppet apply ${PUPPET_APPLY_OPTS} /etc/puppet/manifests/site.pp --detailed-exitcodes

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
