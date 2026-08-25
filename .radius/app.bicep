extension radius

param environment string

@description('Username for the OCI registry the containerImages recipe pushes to (the GitHub actor for ghcr.io).')
@secure()
param registryUsername string

@description('Password/token for the OCI registry the containerImages recipe pushes to (a GitHub token with write:packages for ghcr.io).')
@secure()
param registryPassword string

@secure()
param orderDbPassword string

@secure()
param orderQueuePassword string

resource storeApp 'Radius.Core/applications@2025-08-01-preview' = {
  name: 'aks-store-demo'
  properties: {
    environment: environment
  }
}

resource rabbitmq 'Radius.Messaging/rabbitMQ@2025-08-01-preview' = {
  name: 'rabbitmq'
  properties: {
    environment: environment
    application: storeApp.id
    queue: 'orders'
    codeReference: 'src/order-service/plugins/messagequeue.js#L26'
  }
}

resource mongodb 'Radius.Data/mongoDatabases@2025-08-01-preview' = {
  name: 'mongodb'
  properties: {
    environment: environment
    application: storeApp.id
    database: 'orderdb'
    codeReference: 'src/makeline-service/mongodb.go#L105'
  }
}

resource registryCreds 'Radius.Security/secrets@2025-08-01-preview' = {
  name: 'radius-ghcr-registry-creds'
  properties: {
    environment: environment
    application: storeApp.id
    data: {
      username: {
        value: registryUsername
      }
      password: {
        value: registryPassword
      }
    }
  }
}

resource makelineServiceImage 'Radius.Compute/containerImages@2025-08-01-preview' = {
  name: 'makeline-service-image'
  properties: {
    environment: environment
    application: storeApp.id
    build: {
      source: 'git::https://github.com/willtsai/aks-store-demo.git//src/makeline-service?ref=717ba88d5c06cdec672eeeea591d41ae7bee5d43'
    }
    codeReference: 'src/makeline-service/Dockerfile'
  }
  dependsOn: [
    registryCreds
  ]
}

resource orderServiceImage 'Radius.Compute/containerImages@2025-08-01-preview' = {
  name: 'order-service-image'
  properties: {
    environment: environment
    application: storeApp.id
    build: {
      source: 'git::https://github.com/willtsai/aks-store-demo.git//src/order-service?ref=717ba88d5c06cdec672eeeea591d41ae7bee5d43'
    }
    codeReference: 'src/order-service/Dockerfile'
  }
  dependsOn: [
    registryCreds
  ]
}

resource productServiceImage 'Radius.Compute/containerImages@2025-08-01-preview' = {
  name: 'product-service-image'
  properties: {
    environment: environment
    application: storeApp.id
    build: {
      source: 'git::https://github.com/willtsai/aks-store-demo.git//src/product-service?ref=717ba88d5c06cdec672eeeea591d41ae7bee5d43'
    }
    codeReference: 'src/product-service/Dockerfile'
  }
  dependsOn: [
    registryCreds
  ]
}

resource storeAdminImage 'Radius.Compute/containerImages@2025-08-01-preview' = {
  name: 'store-admin-image'
  properties: {
    environment: environment
    application: storeApp.id
    build: {
      source: 'git::https://github.com/willtsai/aks-store-demo.git//src/store-admin?ref=717ba88d5c06cdec672eeeea591d41ae7bee5d43'
    }
    codeReference: 'src/store-admin/Dockerfile'
  }
  dependsOn: [
    registryCreds
  ]
}

resource storeFrontImage 'Radius.Compute/containerImages@2025-08-01-preview' = {
  name: 'store-front-image'
  properties: {
    environment: environment
    application: storeApp.id
    build: {
      source: 'git::https://github.com/willtsai/aks-store-demo.git//src/store-front?ref=717ba88d5c06cdec672eeeea591d41ae7bee5d43'
    }
    codeReference: 'src/store-front/Dockerfile'
  }
  dependsOn: [
    registryCreds
  ]
}

resource virtualCustomerImage 'Radius.Compute/containerImages@2025-08-01-preview' = {
  name: 'virtual-customer-image'
  properties: {
    environment: environment
    application: storeApp.id
    build: {
      source: 'git::https://github.com/willtsai/aks-store-demo.git//src/virtual-customer?ref=717ba88d5c06cdec672eeeea591d41ae7bee5d43'
    }
    codeReference: 'src/virtual-customer/Dockerfile'
  }
  dependsOn: [
    registryCreds
  ]
}

resource virtualWorkerImage 'Radius.Compute/containerImages@2025-08-01-preview' = {
  name: 'virtual-worker-image'
  properties: {
    environment: environment
    application: storeApp.id
    build: {
      source: 'git::https://github.com/willtsai/aks-store-demo.git//src/virtual-worker?ref=717ba88d5c06cdec672eeeea591d41ae7bee5d43'
    }
    codeReference: 'src/virtual-worker/Dockerfile'
  }
  dependsOn: [
    registryCreds
  ]
}

resource orderServiceContainer 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'order-service'
  properties: {
    environment: environment
    application: storeApp.id
    containers: {
      orderService: {
        image: orderServiceImage.properties.imageReference
        ports: {
          web: {
            containerPort: 3000
          }
        }
        env: {
          ORDER_QUEUE_HOSTNAME: {
            value: rabbitmq.properties.host
          }
          ORDER_QUEUE_NAME: {
            value: 'orders'
          }
          ORDER_QUEUE_PASSWORD: {
            value: orderQueuePassword
          }
          ORDER_QUEUE_PORT: {
            value: '5672'
          }
          ORDER_QUEUE_USERNAME: {
            value: 'username'
          }
        }
      }
    }
    connections: {
      rabbitmq: {
        source: rabbitmq.id
      }
    }
  }
}

resource makelineServiceContainer 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'makeline-service'
  properties: {
    environment: environment
    application: storeApp.id
    containers: {
      makelineService: {
        image: makelineServiceImage.properties.imageReference
        ports: {
          web: {
            containerPort: 3001
          }
        }
        env: {
          ORDER_DB_COLLECTION_NAME: {
            value: 'orders'
          }
          ORDER_DB_NAME: {
            value: 'orderdb'
          }
          ORDER_DB_PASSWORD: {
            value: orderDbPassword
          }
          ORDER_DB_URI: {
            value: 'mongodb://${mongodb.properties.endpoint}:10260/?tls=true&tlsAllowInvalidCertificates=true'
          }
          ORDER_DB_USERNAME: {
            value: 'username'
          }
          ORDER_QUEUE_NAME: {
            value: 'orders'
          }
          ORDER_QUEUE_PASSWORD: {
            value: orderQueuePassword
          }
          ORDER_QUEUE_URI: {
            value: 'amqp://${rabbitmq.properties.host}:5672'
          }
          ORDER_QUEUE_USERNAME: {
            value: 'username'
          }
        }
      }
    }
    connections: {
      mongodb: {
        source: mongodb.id
      }
      rabbitmq: {
        source: rabbitmq.id
      }
    }
  }
}

resource productServiceContainer 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'product-service'
  properties: {
    environment: environment
    application: storeApp.id
    containers: {
      productService: {
        image: productServiceImage.properties.imageReference
        ports: {
          web: {
            containerPort: 3002
          }
        }
      }
    }
  }
}

resource storeAdminContainer 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'store-admin'
  properties: {
    environment: environment
    application: storeApp.id
    containers: {
      storeAdmin: {
        image: storeAdminImage.properties.imageReference
        ports: {
          web: {
            containerPort: 8081
          }
        }
      }
    }
    connections: {
      makelineservice: {
        source: makelineServiceContainer.id
      }
      productservice: {
        source: productServiceContainer.id
      }
    }
  }
}

resource storeFrontContainer 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'store-front'
  properties: {
    environment: environment
    application: storeApp.id
    containers: {
      storeFront: {
        image: storeFrontImage.properties.imageReference
        ports: {
          web: {
            containerPort: 8080
          }
        }
      }
    }
    connections: {
      orderservice: {
        source: orderServiceContainer.id
      }
      productservice: {
        source: productServiceContainer.id
      }
    }
  }
}

resource virtualCustomerContainer 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'virtual-customer'
  properties: {
    environment: environment
    application: storeApp.id
    containers: {
      virtualCustomer: {
        image: virtualCustomerImage.properties.imageReference
        env: {
          ORDERS_PER_HOUR: {
            value: '30'
          }
          ORDER_SERVICE_URL: {
            value: 'http://${orderServiceContainer.properties.hosts['orderService']}:3000/'
          }
        }
      }
    }
    connections: {
      orderservice: {
        source: orderServiceContainer.id
      }
    }
  }
}

resource virtualWorkerContainer 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'virtual-worker'
  properties: {
    environment: environment
    application: storeApp.id
    containers: {
      virtualWorker: {
        image: virtualWorkerImage.properties.imageReference
        env: {
          MAKELINE_SERVICE_URL: {
            value: 'http://${makelineServiceContainer.properties.hosts['makelineService']}:3001'
          }
          ORDERS_PER_HOUR: {
            value: '20'
          }
        }
      }
    }
    connections: {
      makelineservice: {
        source: makelineServiceContainer.id
      }
    }
  }
}
