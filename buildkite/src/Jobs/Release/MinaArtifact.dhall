let Prelude = ../../External/Prelude.dhall

let Cmd = ../../Lib/Cmds.dhall
let S = ../../Lib/SelectFiles.dhall
let D = S.PathPattern

let Pipeline = ../../Pipeline/Dsl.dhall
let JobSpec = ../../Pipeline/JobSpec.dhall

let Command = ../../Command/Base.dhall
let OpamInit = ../../Command/OpamInit.dhall
let Summon = ../../Command/Summon/Type.dhall
let Size = ../../Command/Size.dhall
let Libp2p = ../../Command/Libp2pHelperBuild.dhall
let ConnectToTestnet = ../../Command/ConnectToTestnet.dhall
let UploadGitEnv = ../../Command/UploadGitEnv.dhall
let DockerImage = ../../Command/DockerImage.dhall

let dependsOn = [ { name = "MinaArtifact", key = "build-deb-pkg" } ]
let rosettaDependsOn = [ { name = "MinaArtifact", key = "upload-git-env" } ]

in

Pipeline.build
  Pipeline.Config::{
    spec =
      JobSpec::{
        dirtyWhen = OpamInit.dirtyWhen # [
          S.strictlyStart (S.contains "src"),
          S.strictly (S.contains "Makefile"),
          S.strictlyStart (S.contains "buildkite/src/Jobs/Release/MinaArtifact"),
          S.exactly "buildkite/scripts/build-artifact" "sh",
          S.exactly "buildkite/scripts/connect-to-testnet-on-develop" "sh",
          S.exactly "dockerfiles/scripts/healthcheck-utilities" "sh",
          S.strictlyStart (S.contains "scripts"),
          S.exactly "buildkite/nightly" "txt"
        ],
        path = "Release",
        name = "MinaArtifact"
      },
    steps = [
      Libp2p.step,
      UploadGitEnv.step,
      Command.build
        Command.Config::{
          commands = OpamInit.andThenRunInDocker [
            "DUNE_PROFILE=testnet_postake_medium_curves",
            "AWS_ACCESS_KEY_ID",
            "AWS_SECRET_ACCESS_KEY",
            -- add zexe standardization preprocessing step (see: https://github.com/CodaProtocol/coda/pull/5777)
            "PREPROCESSOR=./scripts/zexe-standardize.sh"
          ] "./buildkite/scripts/build-artifact.sh" # [ Cmd.run "buildkite/scripts/buildkite-artifact-helper.sh ./DOCKER_DEPLOY_ENV" ],
          label = "Build Mina daemon debian package",
          key = "build-deb-pkg",
          target = Size.XLarge,
          artifact_paths = [ S.contains "_build/*.deb" ]
        },

      -- Tests that depend on the debian package
      ConnectToTestnet.step dependsOn,

      -- daemon image
      let daemonSpec = DockerImage.ReleaseSpec::{
        deps=dependsOn,
        service="coda-daemon"
      }

      in

      DockerImage.generateStep daemonSpec,

      -- puppeteered image
      let puppeteeredSpec = DockerImage.ReleaseSpec::{
        deps=dependsOn # [{ name = "MinaArtifact", key = "mina-docker-image" }],
        service="\\\${CODA_SERVICE}-puppeteered",
        extra_args="--build-arg coda_deb_version=\\\${CODA_DEB_VERSION} --build-arg CODA_VERSION=\\\${CODA_VERSION} --build-arg CODA_BRANCH=\\\${CODA_GIT_BRANCH} --build-arg deb_repo=\\\${CODA_DEB_REPO}",
        step_key="puppeteered-docker-image"
      }

      in

      DockerImage.generateStep puppeteeredSpec,

      -- rosetta image
      let rosettaSpec = DockerImage.ReleaseSpec::{
        deps=rosettaDependsOn,
        deploy_env_file="export-git-env-vars.sh",
        service="coda-rosetta",
        version="\\\${DOCKER_TAG}",
        commit = "\\\${GITHASH}",
        extra_args="--build-arg MINA_BRANCH=\\\${BUILDKITE_BRANCH} --build-arg MINA_REPO=\\\${BUILDKITE_PULL_REQUEST_REPO} --cache-from gcr.io/o1labs-192920/mina-rosetta-opam-deps:develop",
        step_key="rosetta-docker-image"
      }

      in

      DockerImage.generateStep rosettaSpec,

      -- rosetta image w/ DUNE_PROFILE=dev
      let rosettaDuneSpec = DockerImage.ReleaseSpec::{
        deps=rosettaDependsOn,
        deploy_env_file="export-git-env-vars.sh",
        service="coda-rosetta",
        version="dev-\\\${DOCKER_TAG}",
        commit = "\\\${GITHASH}",
        extra_args="--build-arg DUNE_PROFILE=dev --build-arg MINA_BRANCH=\\\${BUILDKITE_BRANCH} --build-arg MINA_REPO=\\\${BUILDKITE_PULL_REQUEST_REPO} --cache-from gcr.io/o1labs-192920/mina-rosetta-opam-deps:develop",
        step_key="rosetta-dune-docker-image"
      }

      in

      DockerImage.generateStep rosettaDuneSpec
    ]
  }
