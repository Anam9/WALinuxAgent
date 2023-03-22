#!/usr/bin/env bash

set -euxo pipefail

#
# Set the correct mode for the private SSH key and generate the public key.
#
cd "$HOME"
mkdir ssh
cp "$DOWNLOADSSHKEY_SECUREFILEPATH" ssh
chmod 700 ssh/id_rsa
ssh-keygen -y -f ssh/id_rsa > ssh/id_rsa.pub

#
# Change the ownership of the "ssh" directory we just created, as well as the sources and staging directories.
# Make waagent (UID 1000 in the container) the owner of both locations, so that it can write to them.
# This is needed because building the agent package writes the egg info to the source code directory, and
# tests write their logs to the staging directory.
#
sudo find ssh -exec chown 1000 {} \;
sudo chown 1000 "$BUILD_SOURCESDIRECTORY"
sudo chown 1000 "$BUILD_ARTIFACTSTAGINGDIRECTORY"

#
# Pull the container image used to execute the tests
#
az acr login --name waagenttests --username "$CR_USER" --password "$CR_SECRET"

docker pull waagenttests.azurecr.io/waagenttests:latest

# Azure Pipelines does not allow an empty string as the value for a pipeline parameter; instead we use "-" to indicate
# an empty value. Change "-" to "" for the variables that capture the parameter values.
if [[ $IMAGE == "-" ]]; then
    IMAGE=""
fi
if [[ $LOCATION == "-" ]]; then
    LOCATION=""
fi
if [[ $VM_SIZE == "-" ]]; then
    VM_SIZE=""
fi

# A test failure will cause automation to exit with an error code and we don't want this script to stop so we force the command
# to succeed and capture the exit code to return it at the end of the script.
echo "exit 0" > /tmp/exit.sh

docker run --rm \
    --volume "$BUILD_SOURCESDIRECTORY:/home/waagent/WALinuxAgent" \
    --volume "$HOME"/ssh:/home/waagent/.ssh \
    --volume "$BUILD_ARTIFACTSTAGINGDIRECTORY":/home/waagent/logs \
    --env AZURE_CLIENT_ID \
    --env AZURE_CLIENT_SECRET \
    --env AZURE_TENANT_ID \
    waagenttests.azurecr.io/waagenttests \
    bash --login -c \
      "lisa \
          --runbook \$HOME/WALinuxAgent/tests_e2e/orchestrator/runbook.yml \
          --log_path \$HOME/logs/lisa \
          --working_path \$HOME/logs/lisa \
          -v cloud:$CLOUD \
          -v subscription_id:$SUBSCRIPTION_ID \
          -v identity_file:\$HOME/.ssh/id_rsa \
          -v test_suites:\"$TEST_SUITES\" \
          -v log_path:\$HOME/logs \
          -v collect_logs:\"$COLLECT_LOGS\" \
          -v keep_environment:\"$KEEP_ENVIRONMENT\" \
          -v image:\"$IMAGE\" \
          -v location:\"$LOCATION\" \
          -v vm_size:\"$VM_SIZE\"" \
|| echo "exit $?" > /tmp/exit.sh

#
# Retake ownership of the source and staging directories (note that the former does not need to be done recursively; also, we don't need to
# retake ownership of the ssh directory)
#
sudo chown "$USER" "$BUILD_SOURCESDIRECTORY"
sudo find "$BUILD_ARTIFACTSTAGINGDIRECTORY" -exec chown "$USER" {} \;

# The LISA run will produce a tree similar to
#
#    $BUILD_ARTIFACTSTAGINGDIRECTORY/lisa/20221130
#    $BUILD_ARTIFACTSTAGINGDIRECTORY/lisa/20221130/20221130-160013-749
#    $BUILD_ARTIFACTSTAGINGDIRECTORY/lisa/20221130/20221130-160013-749/environments
#    $BUILD_ARTIFACTSTAGINGDIRECTORY/lisa/20221130/20221130-160013-749/lisa-20221130-160013-749.log
#    $BUILD_ARTIFACTSTAGINGDIRECTORY/lisa/20221130/20221130-160013-749/lisa.junit.xml
#    etc
#
# Remove the 2 levels of the tree that indicate the time of the test run to make navigation
# in the Azure Pipelines UI easier. Also, move the lisa log one level up and remove some of
# the logs that are not needed
#
mv "$BUILD_ARTIFACTSTAGINGDIRECTORY"/lisa/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]/*/* "$BUILD_ARTIFACTSTAGINGDIRECTORY"/lisa
rm -r "$BUILD_ARTIFACTSTAGINGDIRECTORY"/lisa/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]
mv "$BUILD_ARTIFACTSTAGINGDIRECTORY"/lisa/lisa-*.log "$BUILD_ARTIFACTSTAGINGDIRECTORY"
rm "$BUILD_ARTIFACTSTAGINGDIRECTORY"/lisa/messages.log

cat /tmp/exit.sh
bash /tmp/exit.sh