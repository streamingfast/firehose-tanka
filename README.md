## StreamingFast Firehose - Tanka Recipes

This repository contains Tanka recipes to deploy Firehose to a Kubernetes cluster for a given network easily. It also contains sample environments for various networks.

> **Note** We uses those recipes for our own deployment(s) which are made on Google Cloud Platform (GCP), the recipes are meant over to be deployment agnostic and their should support any K8S cluster. There might be however still some code path expecting GCP environment, we invite to open Issues/PRs so when can solve that.

### Getting Started

1. Install [Tanka CLI named `tk`](https://tanka.dev/install) and also the [Jsonnet Bundler CLI named `jb`](https://tanka.dev/install#jsonnet-bundler).
1. Create a directory that will contain your deployment somewhere:

    ```
    mkdir firehose-k8s
    cd firehose-k8s
    ```

1. In this folder, create a file named `jsonnetfile.json` with the following content:

    ```
    cat <<- "EOD" > jsonnetfile.json
    {
      "version": 1,
      "dependencies": [
        {
          "source": {
            "git": {
              "remote": "https://github.com/streamingfast/firehose-tanka.git"
            }
          },
          "version": "master"
        }
      ]
    }
    EOD
    ```

1. Install the Jsonnet dependencies:

    ```
    jb install
    ```


