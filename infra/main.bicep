targetScope = 'resourceGroup'

@description('Azure region')
param location string = 'centralindia'

@description('Existing resource group name')
param resourceGroupName string = resourceGroup().name

@description('Frontend storage account name')
param storageAccountName string = 'capstonefe1790267848'

@description('Backend App Service Plan name')
param appServicePlanName string = 'capstone-backend-plan'

@description('Backend Web App name')
param webAppName string = 'capstone-backend-1790273810'

@description('Cosmos DB account name')
param cosmosAccountName string = 'capstonecosmos1790272312'

@description('Virtual Network name')
param vnetName string = 'capstone-vnet'

@description('Application Gateway name')
param applicationGatewayName string = 'capstone-appgw'

@description('WAF policy name')
param wafPolicyName string = 'capstone-waf-policy'

resource appServicePlan 'Microsoft.Web/serverfarms@2024-11-01' = {
  name: appServicePlanName
  location: location
  kind: 'linux'

  sku: {
    name: 'B1'
    tier: 'Basic'
    capacity: 1
  }

  properties: {
    reserved: true
  }
}

output deploymentResourceGroup string = resourceGroupName
output deploymentLocation string = location
output appServicePlan string = appServicePlan.name
output storageAccount string = storageAccountName
output webApp string = webAppName
output cosmosAccount string = cosmosAccountName
output vnet string = vnetName
output applicationGateway string = applicationGatewayName
output wafPolicy string = wafPolicyName

resource vnet 'Microsoft.Network/virtualNetworks@2024-10-01' = {
  name: vnetName
  location: location

  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/16'
      ]
    }

    subnets: [
      {
        name: 'AppSubnet'
        properties: {
          addressPrefix: '10.0.1.0/24'

          delegations: [
            {
              name: 'webAppDelegation'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
              }
            }
          ]
        }
      }

      {
        name: 'DataSubnet'
        properties: {
          addressPrefix: '10.0.2.0/24'
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }

      {
        name: 'GatewaySubnet'
        properties: {
          addressPrefix: '10.0.3.0/24'
        }
      }

      {
        name: 'AppGatewaySubnet'
        properties: {
          addressPrefix: '10.0.4.0/24'

          serviceEndpoints: [
            {
              service: 'Microsoft.Web'
            }
          ]
        }
      }
    ]
  }
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  kind: 'StorageV2'

  sku: {
    name: 'Standard_LRS'
  }

  properties: {
    accessTier: 'Hot'
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
  }
}


resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'capstone-appinsights'
  location: location
  kind: 'web'

  properties: {
    Application_Type: 'web'
    IngestionMode: 'LogAnalytics'
    RetentionInDays: 90
  }
}

resource cosmosAccount 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' = {
  name: cosmosAccountName
  location: location
  kind: 'GlobalDocumentDB'

  properties: {
    databaseAccountOfferType: 'Standard'

    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
      maxIntervalInSeconds: 5
      maxStalenessPrefix: 100
    }

    enableAutomaticFailover: true
    enableFreeTier: true
    minimalTlsVersion: 'Tls12'
    publicNetworkAccess: 'Disabled'

    locations: [
      {
        locationName: location
        failoverPriority: 0
        isZoneRedundant: false
      }
    ]
  }
}

resource cosmosDatabase 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2024-11-15' = {
  parent: cosmosAccount
  name: 'capstone-db'

  properties: {
    resource: {
      id: 'capstone-db'
    }
  }
}

resource cosmosContainer 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-11-15' = {
  parent: cosmosDatabase
  name: 'tasks'

  properties: {
    resource: {
      id: 'tasks'

      partitionKey: {
        paths: [
          '/userId'
        ]
        kind: 'Hash'
      }

      indexingPolicy: {
        indexingMode: 'consistent'
        automatic: true

        includedPaths: [
          {
            path: '/*'
          }
        ]

        excludedPaths: [
          {
            path: '/"_etag"/?'
          }
        ]
      }
    }
  }
}

resource cosmosPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: 'capstone-cosmos-pe'
  location: location

  properties: {
    subnet: {
      id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'DataSubnet')
    }

    privateLinkServiceConnections: [
      {
        name: 'capstone-cosmos-connection'
        properties: {
          privateLinkServiceId: cosmosAccount.id
          groupIds: [
            'Sql'
          ]
        }
      }
    ]
  }
}

resource cosmosPrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.documents.azure.com'
  location: 'global'
}

resource cosmosPrivateDnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: cosmosPrivateDnsZone
  name: 'capstone-vnet-dns-link'
  location: 'global'

  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}

resource cosmosDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: cosmosPrivateEndpoint
  name: 'capstone-cosmos-dns-zone-group'

  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'cosmos'
        properties: {
          privateDnsZoneId: cosmosPrivateDnsZone.id
        }
      }
    ]
  }
}

resource webApp 'Microsoft.Web/sites@2024-11-01' = {
  name: webAppName
  location: location
  kind: 'app,linux'

  identity: {
    type: 'SystemAssigned'
  }

  properties: {
    httpsOnly: true
    serverFarmId: appServicePlan.id

    siteConfig: {
      linuxFxVersion: 'PYTHON|3.11'
      minTlsVersion: '1.2'
      ftpsState: 'FtpsOnly'

      appCommandLine: 'gunicorn --bind=0.0.0.0:8000 app:app'

      cors: {
        allowedOrigins: [
          'https://capstonefe1790267848.z29.web.core.windows.net'
        ]
        supportCredentials: false
      }

      appSettings: [
        {
          name: 'TENANT_ID'
          value: '785707d0-a503-4e58-8a6e-114f5db483b4'
        }
        {
          name: 'API_AUDIENCE'
          value: 'api://9e3535bc-c789-4853-844e-899985a12461'
        }
        {
          name: 'COSMOS_ENDPOINT'
          value: cosmosAccount.properties.documentEndpoint
        }
        {
          name: 'COSMOS_DATABASE'
          value: 'capstone-db'
        }
        {
          name: 'COSMOS_CONTAINER'
          value: 'tasks'
        }
        {
          name: 'TOKEN_ISSUER'
          value: 'https://sts.windows.net/785707d0-a503-4e58-8a6e-114f5db483b4/'
        }
        {
          name: 'SCM_DO_BUILD_DURING_DEPLOYMENT'
          value: 'true'
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'ApplicationInsightsAgent_EXTENSION_VERSION'
          value: '~3'
        }
      ]
    }
  }

  dependsOn: [
    cosmosDnsZoneGroup
  ]
}


resource webAppVnetConnection 'Microsoft.Web/sites/virtualNetworkConnections@2024-11-01' = {
  parent: webApp
  name: 'capstone-vnet-connection'

  properties: {
    vnetResourceId: resourceId(
      'Microsoft.Network/virtualNetworks/subnets',
      vnetName,
      'AppSubnet'
    )
    isSwift: true
  }
}


resource cosmosRoleAssignment 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-11-15' = {
  parent: cosmosAccount
  name: guid(cosmosAccount.id, webAppName, 'cosmos-data-contributor')

  properties: {
    roleDefinitionId: '${cosmosAccount.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002'
    principalId: webApp.identity.principalId
    scope: cosmosAccount.id
  }
}

resource wafPolicy 'Microsoft.Network/ApplicationGatewayWebApplicationFirewallPolicies@2024-07-01' = {
  name: wafPolicyName
  location: location

  properties: {
    policySettings: {
      state: 'Enabled'
      mode: 'Detection'
      requestBodyCheck: false
      fileUploadEnforcement: true
      fileUploadLimitInMb: 100
      maxRequestBodySizeInKb: 128
      requestBodyEnforcement: true
      requestBodyInspectLimitInKB: 128
    }

    managedRules: {
      managedRuleSets: [
        {
          ruleSetType: 'Microsoft_DefaultRuleSet'
          ruleSetVersion: '2.1'
        }
      ]
    }
  }
}

resource appGatewayPublicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'capstone-appgw-pip'
  location: location
  sku: {
    name: 'Standard'
  }

  properties: {
    publicIPAllocationMethod: 'Static'

    dnsSettings: {
      domainNameLabel: 'capstone-appgw-1790273810'
    }
  }
}



resource appGateway 'Microsoft.Network/applicationGateways@2025-03-01' = {
  name: applicationGatewayName
  location: location

  properties: {
    sku: {
      name: 'WAF_v2'
      tier: 'WAF_v2'
      capacity: 1
    }

    firewallPolicy: {
      id: wafPolicy.id
    }

    gatewayIPConfigurations: [
      {
        name: 'appGatewayIpConfig'
        properties: {
          subnet: {
            id: resourceId(
              'Microsoft.Network/virtualNetworks/subnets',
              vnetName,
              'AppGatewaySubnet'
            )
          }
        }
      }
    ]

    frontendIPConfigurations: [
      {
        name: 'appGatewayFrontendIP'
        properties: {
          publicIPAddress: {
            id: appGatewayPublicIp.id
          }
        }
      }
    ]

    frontendPorts: [
      {
        name: 'appGatewayFrontendPort'
        properties: {
          port: 80
        }
      }
    ]

    backendAddressPools: [
      {
        name: 'appGatewayBackendPool'
        properties: {
          backendAddresses: [
            {
              fqdn: webApp.properties.defaultHostName
            }
          ]
        }
      }
    ]

    probes: [
      {
        name: 'capstone-backend-health'
        properties: {
          protocol: 'Https'
          path: '/api/health'
          interval: 30
          timeout: 30
          unhealthyThreshold: 3
          host: webApp.properties.defaultHostName

          match: {
            statusCodes: [
              '200-399'
            ]
          }
        }
      }
    ]

    backendHttpSettingsCollection: [
      {
        name: 'appGatewayBackendHttpSettings'
        properties: {
          port: 443
          protocol: 'Https'
          requestTimeout: 30
          pickHostNameFromBackendAddress: true

          probe: {
            id: resourceId(
              'Microsoft.Network/applicationGateways/probes',
              applicationGatewayName,
              'capstone-backend-health'
            )
          }
        }
      }
    ]

    httpListeners: [
      {
        name: 'appGatewayHttpListener'
        properties: {
          protocol: 'Http'

          frontendIPConfiguration: {
            id: resourceId(
              'Microsoft.Network/applicationGateways/frontendIPConfigurations',
              applicationGatewayName,
              'appGatewayFrontendIP'
            )
          }

          frontendPort: {
            id: resourceId(
              'Microsoft.Network/applicationGateways/frontendPorts',
              applicationGatewayName,
              'appGatewayFrontendPort'
            )
          }
        }
      }
    ]
    requestRoutingRules: [
      {
        name: 'rule1'
        properties: {
          ruleType: 'Basic'
          priority: 100

          httpListener: {
            id: resourceId(
              'Microsoft.Network/applicationGateways/httpListeners',
              applicationGatewayName,
              'appGatewayHttpListener'
            )
          }

          backendAddressPool: {
            id: resourceId(
              'Microsoft.Network/applicationGateways/backendAddressPools',
              applicationGatewayName,
              'appGatewayBackendPool'
            )
          }

          backendHttpSettings: {
            id: resourceId(
              'Microsoft.Network/applicationGateways/backendHttpSettingsCollection',
              applicationGatewayName,
              'appGatewayBackendHttpSettings'
            )
          }
        }
      }
    ]
  }
}

