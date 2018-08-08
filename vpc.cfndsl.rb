
CloudFormation do

  # Render AZ conditions
  az_conditions(maximum_availability_zones)
  max_nat_conditions(maximum_availability_zones)

  # Render NAT Gateway and EIP Conditions
  maximum_availability_zones.times do |x|
    Condition("Nat#{x}EIPRequired", FnEquals(Ref("Nat#{x}EIPAllocationId"), 'dynamic'))
    Condition("NatIPAddress#{x}Required",FnAnd([
        Condition("NatGateway#{x}Exist"),
        Condition("Nat#{x}EIPRequired")
    ]))
  end

  # VPC Itself
  VPC('VPC') do
    CidrBlock(
        FnJoin('',
            [Ref('NetworkPrefix'),
                '.',
                Ref('StackOctet'),
                '.0.0/',
                Ref('StackMask')]
        )
    )
    EnableDnsSupport true
    EnableDnsHostnames true
  end

  dns_domain = FnJoin('.', [
      Ref('EnvironmentName'), Ref('DnsDomain')
  ])

  Route53_HostedZone('HostedZone') do
    Name dns_domain
  end

  EC2_DHCPOptions('DHCPOptionSet') do
    DomainName dns_domain
    DomainNameServers ['AmazonProvidedDNS']
  end

  EC2_VPCDHCPOptionsAssociation('DHCPOptionsAssociation') do
    VpcId Ref('VPC')
    DhcpOptionsId Ref('DHCPOptionSet')
  end

  EC2_InternetGateway('InternetGateway')

  EC2_VPCGatewayAttachment('AttachGateway') do
    VpcId Ref('VPC')
    InternetGatewayId Ref('InternetGateway')
  end

  EC2_NetworkAcl('PublicNetworkAcl') do
    VpcId Ref('VPC')
  end

  public_acl_rules.each do |type,entries|
    entries.each do |entry|
      EC2_NetworkAclEntry("#{type}#{entry['number']}") {
        NetworkAclId Ref('PublicNetworkAcl')
        RuleNumber entry['number']
        Protocol entry['protocol'] || '6'
        RuleAction (entry['allow'] ? 'allow' : 'deny')
        Egress (type == 'outbound' ? true : false)
        CidrBlock entry['cidr'] || '0.0.0.0/0'
        PortRange ({ From: entry['from'], To: entry['to'] || entry['from'] })
      }
    end
  end

  # Public subnets route table
  EC2_RouteTable('RouteTablePublic') do
    VpcId Ref('VPC')
    Tags [ { Key: 'Name', Value: FnJoin( "", [ Ref('EnvironmentName'), "-public" ]) }]
  end

  # Public subnet internet route
  EC2_Route('PublicRouteOutToInternet') do
    DependsOn ['AttachGateway']
    RouteTableId Ref("RouteTablePublic")
    DestinationCidrBlock '0.0.0.0/0'
    GatewayId Ref("InternetGateway")
  end


  maximum_availability_zones.times do |az|

    # Private subnet route tables
    EC2_RouteTable("RouteTablePrivate#{az}") do
      Condition "Az#{az}"
      VpcId Ref('VPC')
      Tags [ { Key: 'Name', Value: FnJoin("", [ Ref('EnvironmentName'), "-private#{az}" ]) } ]
    end


    # Nat Gateway IPs and Nat Gateways
    EC2_EIP("NatIPAddress#{az}") do
      DependsOn ["AttachGateway"]
      Condition("NatIPAddress#{az}Required")
      Domain 'vpc'
    end

    EC2_NatGateway("NatGateway#{az}") do
      Condition "NatGateway#{az}Exist"
      # If EIP is passed manually as param, use that EIP, otherwise use one from
      # generated by CloudFormation
      AllocationId FnIf("Nat#{az}EIPRequired",
          FnGetAtt("NatIPAddress#{az}",'AllocationId'),
          Ref("Nat#{az}EIPAllocationId")
      )
      SubnetId Ref("SubnetPublic#{az}")
    end

    # Private subnet internet route through NAT Gateway

    EC2_Route("RouteOutToInternet#{az}") do
      Condition "RoutedByNat#{az}"
      DependsOn ["NatGateway#{az}"]
      RouteTableId Ref("RouteTablePrivate#{az}")
      DestinationCidrBlock '0.0.0.0/0'
      NatGatewayId Ref("NatGateway#{az}")
    end

    EC2_Route("RouteOutToInternet#{az}Nat0") do
      Condition "RoutedBySingleNat#{az}"
      DependsOn ["NatGateway0"]
      RouteTableId Ref("RouteTablePrivate#{az}")
      DestinationCidrBlock '0.0.0.0/0'
      NatGatewayId Ref("NatGateway0")
    end

  end



  # Create defined subnets
  subnets.each { |name, config|
    az_create_subnets(
        config['allocation'],
        config['name'],
        config['type'],
        'VPC',
        maximum_availability_zones
    )
  }

  route_tables = az_conditional_resources_internal('RouteTablePrivate', maximum_availability_zones)

  EC2_VPCEndpoint('VPCEndpoint') do
    VpcId Ref('VPC')
    PolicyDocument({
      Version:"2012-10-17",
          Statement:[{
          Effect:"Allow",
          Principal: "*",
          Action:["s3:*"],
          Resource:["arn:aws:s3:::*"]
      }]
    })
    ServiceName FnJoin("", [ "com.amazonaws.", Ref("AWS::Region"), ".s3"])
    RouteTableIds route_tables

  end

  if securityGroups.key?('ops')
    EC2_SecurityGroup('SecurityGroupOps') do
      VpcId Ref('VPC')
      GroupDescription 'Ops External Access'
      SecurityGroupIngress sg_create_rules(securityGroups['ops'], ip_blocks)
    end
  end

  if securityGroups.key?('dev')
    EC2_SecurityGroup('SecurityGroupDev') do
      VpcId Ref('VPC')
      GroupDescription 'Dev Team Access'
      SecurityGroupIngress sg_create_rules(securityGroups['dev'], ip_blocks)
    end
  end

  if securityGroups.key?('backplane')
    EC2_SecurityGroup('SecurityGroupBackplane') do
      VpcId Ref('VPC')
      GroupDescription 'Backplane SG'
      SecurityGroupIngress sg_create_rules(securityGroups['backplane'], ip_blocks)
    end
  end

  if enable_transit_vpc
    VPNGateway('VGW') do
      Type 'ipsec.1'
      Tags [
        { Key: 'Name', Value: FnJoin( "", [ Ref('EnvironmentName'), "-VGW"]) },
        { Key: 'transitvpc:spoke', Value: Ref('EnableTransitVPC') }
      ]
    end

    VPCGatewayAttachment('AttachVGWToVPC') do
      VpcId Ref('VPC')
      VpnGatewayId Ref('VGW')
    end

    VPNGatewayRoutePropagation('PropagateRoute') do
      DependsOn ['AttachVGWToVPC']
      RouteTableIds route_tables
      VpnGatewayId Ref('VGW')
    end
  end

  # Outputs
  Output("VPCId") { Value(Ref('VPC')) }
  Output("SecurityGroupOps") { Value(Ref('SecurityGroupOps')) }
  Output("SecurityGroupDev") { Value(Ref('SecurityGroupDev')) }
  Output("SecurityGroupBackplane") { Value(Ref('SecurityGroupBackplane')) }

  nat_ip_list = nat_gateway_ips_list_internal(maximum_availability_zones)
  Output('NatGatewayIps') {
    Value(FnJoin(',', nat_ip_list))
  }

end
