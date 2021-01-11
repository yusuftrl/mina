#!/bin/bash

# TODO: make sure terraform installed

# implicit flags needed to be passed in via runInDocker
# BUILDKITE_GS_APPLICATION_CREDENTIALS_JSON
# $AWS_ACCESS_KEY_ID $AWS_SECRET_ACCESS_KEY

source DOCKER_DEPLOY_ENV
DAEMON_TAG="gcr.io/o1labs-192920/coda-daemon:${CODA_VERSION}-${CODA_GIT_HASH}"
ARCHIVE_TAG="gcr.io/o1labs-192920/coda-archive:${CODA_VERSION}-${CODA_GIT_HASH}"

if [ ! -z $NIGHTLY ]; then
  echo "Deploying Nightly"

  # Authenticate terraform for gcp
  echo "$BUILDKITE_GS_APPLICATION_CREDENTIALS_JSON" > /tmp/gcp_creds.json
  export GOOGLE_APPLICATION_CREDENTIALS=/tmp/gcp_creds.json

  cd automation/terraform/testnets/nightly
  terraform init
  terraform destroy -auto-approve
  terraform apply -var="coda_image=${DAEMON_TAG}" -var="coda_archive_image=${ARCHIVE_TAG}" -auto-approve

else
  echo "Not deploying Nightly"
fi
