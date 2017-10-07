#!/bin/bash

DXLENVIRONMENT_DIR=/dxlenvironment
DXLENVIRONMENT_CONFIG_DIR=$DXLENVIRONMENT_DIR/config
DXLENVIRONMENT_SITES_ENABLED_DIR=$DXLENVIRONMENT_CONFIG_DIR/sites-enabled
DXLENVIRONMENT_WEB_CONSOLE_SITE_FILE=$DXLENVIRONMENT_SITES_ENABLED_DIR/webconsole
DXLENVIRONMENT_WEB_CONSOLE_CONFIG_DIR=$DXLENVIRONMENT_CONFIG_DIR/webconsole
DXLENVIRONMENT_CLOUDCMD_CONFIG_FILE=$DXLENVIRONMENT_WEB_CONSOLE_CONFIG_DIR/cloudcmd.json
DXLENVIRONMENT_CLOUDCMD_CREDS_SCRIPT=$DXLENVIRONMENT_WEB_CONSOLE_CONFIG_DIR/set_cloudcmd_creds

DOCKER_HOSTNAME=dockerhost
DOCKER_HOSTIP=$(ip route | sed -n 's/.*default via \([^ ]*\).*/\1/p')

DVOL=/opendxl
DVOL_CONFIG_DIR=$DVOL/config
DVOL_WEB_CONSOLE_CONFIG_DIR=$DVOL_CONFIG_DIR/webconsole
DVOL_CLOUDCMD_CONFIG_FILE=$DVOL_WEB_CONSOLE_CONFIG_DIR/cloudcmd.json
DVOL_CLOUDCMD_CREDS_SCRIPT=$DVOL_WEB_CONSOLE_CONFIG_DIR/set_cloudcmd_creds
DVOL_SITES_ENABLED_DIR=$DVOL_CONFIG_DIR/sites-enabled
DVOL_WEB_CONSOLE_SITE_FILE=$DVOL_SITES_ENABLED_DIR/webconsole
DVOL_KEYSTORE_DIR=$DVOL/keystore
DVOL_ENVIRONMENT_CA_CERT_FILE=$DVOL_KEYSTORE_DIR/ca-environment.crt
DVOL_ENVIRONMENT_CA_KEY_FILE=$DVOL_KEYSTORE_DIR/ca-environment.key
DVOL_ENVIRONMENT_CA_CSR_FILE=$DVOL_KEYSTORE_DIR/ca-environment.csr
DVOL_WEB_CONSOLE_CERT_FILE=$DVOL_KEYSTORE_DIR/cloudcmd.crt
DVOL_WEB_CONSOLE_CERT_BUNDLE_FILE=$DVOL_KEYSTORE_DIR/cloudcmd-bundle.crt
DVOL_WEB_CONSOLE_KEY_FILE=$DVOL_KEYSTORE_DIR/cloudcmd.key
DVOL_WEB_CONSOLE_CSR_FILE=$DVOL_KEYSTORE_DIR/cloudcmd.csr
DVOL_V3_EXT_FILE=$DVOL_KEYSTORE_DIR/v3.ext
REQUIRED_CERT_FILES=($DVOL_WEB_CONSOLE_CERT_BUNDLE_FILE $DVOL_WEB_CONSOLE_KEY_FILE)
DVOL_SCRIPTS_DIR=$DVOL/scripts
DVOL_LOGS_DIR=$DVOL/logs

NGINX_SITES_ENABLED_DIR=/etc/nginx/sites-enabled

CERT_PASS=OpenDxlEnvironment
CERT_DAYS=3650

#
# Function that is invoked when the script fails.
#
# $1 - The message to display prior to exiting.
#
function fail() {
    echo $1
    echo "Exiting."
    exit 1
}

#
# Create directories
#
if [ ! -d $DVOL_KEYSTORE_DIR ]; then
    echo "Creating keystore directory..."
    mkdir -p $DVOL_KEYSTORE_DIR \
        || { fail 'Error creating keystore directory.'; }
fi
if [ ! -d $DVOL_LOGS_DIR ]; then
    echo "Creating logs directory..."
    mkdir -p $DVOL_LOGS_DIR || { fail 'Error creating logs directory.'; }
fi
if [ ! -d $DVOL_SITES_ENABLED_DIR ]; then
    echo "Creating sites enabled directory..."
    mkdir -p $DVOL_SITES_ENABLED_DIR \
        || { fail 'Error creating sites enabled directory.'; }
fi
if [ ! -d $DVOL_WEB_CONSOLE_CONFIG_DIR ]; then
    echo "Creating web console config directory..."
    mkdir -p $DVOL_WEB_CONSOLE_CONFIG_DIR \
        || { fail 'Error creating web console config directory.'; }
fi

# Add entry for docker host to the /etc/hosts file
if [ -n $DOCKER_HOSTIP ]; then
    echo "Using docker host IP address ${DOCKER_HOSTIP}"
    if ! grep -q $DOCKER_HOSTNAME /etc/hosts 2>/dev/null; then
        echo -e "\n${DOCKER_HOSTIP} ${DOCKER_HOSTNAME}" >> /etc/hosts
        if [ $? -ne 0 ]; then
            echo "Failed to add docker host entry to /etc/hosts file" >&2
        fi
    fi
else
    echo "Unable to determine docker host IP address" >&2
fi

#
# Check and possibly generate certificate information
#

# Check to see if any of the required cert files exist
found_cert_file=false
for f in "${REQUIRED_CERT_FILES[@]}"
do
    if [ -f $f ]; then
        found_cert_file=true
        break
	fi
done

if [ $found_cert_file = true ]
then
    # At least one file exists, make sure they all exist
    found_all_files=true
    for f in "${REQUIRED_CERT_FILES[@]}"
    do
        if [ ! -f $f ]; then
            found_all_files=false
            echo "Required cert file not found: $f"
        fi
    done
    if [ $found_all_files = false ]; then
        fail 'Required cert files were not found.'
    fi
else
    # No cert files exist, generate them.
    echo "Generating certificate files..."

    # Create Environment CA
    openssl req -new -passout pass:"$CERT_PASS" \
        -subj "/CN=OpenDxlEnvironmentCA" -x509 -days $CERT_DAYS \
        -extensions v3_ca -keyout $DVOL_ENVIRONMENT_CA_KEY_FILE \
        -out $DVOL_ENVIRONMENT_CA_CERT_FILE \
        || { fail 'Error creating environment CA.'; }

    # Create web console CSR
    openssl req -out $DVOL_WEB_CONSOLE_CSR_FILE \
        -subj "/CN=OpenDxlEnvironmentWebConsole" -new -newkey rsa:2048 -nodes \
        -keyout $DVOL_WEB_CONSOLE_KEY_FILE \
        || { fail 'Error generating web console CSR.'; }

    # Create V3 extension file (CA is false)
    echo "basicConstraints=CA:FALSE" > $DVOL_V3_EXT_FILE \
        || { fail 'Error creating web console V3 extension file.'; }

    # Sign the web console CSR
    openssl x509 -req -passin pass:"$CERT_PASS" -in $DVOL_WEB_CONSOLE_CSR_FILE \
        -CA $DVOL_ENVIRONMENT_CA_CERT_FILE \
        -CAkey $DVOL_ENVIRONMENT_CA_KEY_FILE -CAcreateserial \
        -out $DVOL_WEB_CONSOLE_CERT_FILE -days $CERT_DAYS \
        -extfile $DVOL_V3_EXT_FILE \
        || { fail 'Error signing web console CSR.'; }

    # Concatenate web console and CA cert file into cert bundle
    cp $DVOL_WEB_CONSOLE_CERT_FILE $DVOL_WEB_CONSOLE_CERT_BUNDLE_FILE \
        || { fail 'Error copying web console cert into cert bundle.'; }
    cat $DVOL_ENVIRONMENT_CA_CERT_FILE >> $DVOL_WEB_CONSOLE_CERT_BUNDLE_FILE \
        || { fail 'Error appending environment CA cert into cert bundle.'; }

    # Remove temporary files
    rm -f $DVOL_KEYSTORE_DIR/*.csr
    rm -f $DVOL_KEYSTORE_DIR/*.srl
    rm -f $DVOL_V3_EXT_FILE
fi

#
# Configure nginx proxy to web console site
#
if [ ! -f $DVOL_WEB_CONSOLE_SITE_FILE ]; then
    cp $DXLENVIRONMENT_WEB_CONSOLE_SITE_FILE $DVOL_WEB_CONSOLE_SITE_FILE
fi
rm -rf $NGINX_SITES_ENABLED_DIR
ln -sf $DVOL_SITES_ENABLED_DIR $NGINX_SITES_ENABLED_DIR
service nginx restart

#
# Setup cloud commander configuration files
#
if [ ! -f $DVOL_CLOUDCMD_CONFIG_FILE ]; then
    cp $DXLENVIRONMENT_CLOUDCMD_CONFIG_FILE $DVOL_CLOUDCMD_CONFIG_FILE
fi
if [ ! -f $DVOL_CLOUDCMD_CREDS_SCRIPT ]; then
    cp $DXLENVIRONMENT_CLOUDCMD_CREDS_SCRIPT $DVOL_CLOUDCMD_CREDS_SCRIPT
fi

ln -sf $DVOL_CLOUDCMD_CONFIG_FILE /root/.cloudcmd.json

# Run cloud commander
cloudcmd
