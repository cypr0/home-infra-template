package config

import (
	"net"
	"list"
)

#Config: {
	proxmox:           #Proxmox
	opnsense:          #OPNsense
	network:           #Network
	kubernetes:        #Kubernetes
	gateways:          #Gateways
	repository:        #Repository
	cloudflare:        #Cloudflare
	cilium:            #Cilium
	autoscaler?:       #Autoscaler
	mgmt_nodes: [...#Node]
	controlplane_nodes: [...#Node]
	worker_nodes?: [...#Node]

	// Ensure we have at least one management node
	mgmt_nodes: list.MinItems(1)
	// Ensure we have at least one controlplane
	controlplane_nodes: list.MinItems(1)
	// Worker nodes are optional when using autoscaler

	// BGP enabled only if all fields are set
	cilium_bgp_enabled: cilium.bgp_enabled == true && cilium.bgp.router_addr != "" && cilium.bgp.router_asn != "" && cilium.bgp.node_asn != ""
}

#Proxmox: {
	// Proxmox API URL
	api_url: string & =~"^https?://.+"
	// Proxmox node name
	node: string & !=""
	// Proxmox user (e.g., root@pam)
	user: string & !=""
	// API token (optional)
	token?: string
	// Storage pool name
	storage: string & !=""
	// Network bridge
	bridge: string & !=""
}

#OPNsense: {
	// OPNsense API URL
	api_url: string & =~"^https?://.+"
	// API key
	api_key: string
	// API secret
	api_secret: string
}

#Network: {
	// CIDR for node IPs (must be /24 or larger) - can be node_cidr or lan_cidr
	node_cidr?: net.IPCIDR
	lan_cidr?: net.IPCIDR
	// VPN network (optional)
	vpn_cidr?: net.IPCIDR
	// DNS servers to use
	dns_servers: [...net.IPv4]
	// NTP servers to use
	ntp_servers: [...net.IPv4]
	// Default gateway (optional, auto-calculated from node_cidr/lan_cidr)
	default_gateway?: net.IPv4 & !=""
}

#Kubernetes: {
	// Pod CIDR
	pod_cidr: *"10.42.0.0/16" | net.IPCIDR
	// Service CIDR
	svc_cidr: *"10.43.0.0/16" | net.IPCIDR
	api: {
		// API server VIP
		addr: net.IPv4
		// Additional TLS SANs
		tls_sans: [...string]
	}
}

#Gateways: {
	// External gateway IP for public ingress
	external: net.IPv4
	// Internal gateway IP for internal services
	internal: net.IPv4
}

#Repository: {
	// GitHub repository (owner/repo)
	name: string & =~"^[a-zA-Z0-9_-]+/[a-zA-Z0-9_-]+$"
	// Branch name
	branch: *"main" | string
	// Flux path
	flux_path: *"kubernetes" | string
}

#Cloudflare: {
	// Domain name
	domain: string & =~"^[a-z0-9.-]+$"
	// API token
	api_token: string
	// Email (optional, can be empty)
	email?: string
}

#Cilium: {
	// Enable BGP
	bgp_enabled: *false | bool
	bgp: {
		// BGP router IP
		router_addr: string
		// BGP router ASN
		router_asn: string
		// BGP node ASN
		node_asn: string
	}
}

#Autoscaler: {
	// Enable autoscaler for worker nodes
	enabled: *false | bool
	// Minimum number of worker nodes
	min_workers: *0 | >=0 & <=100
	// Maximum number of worker nodes
	max_workers: *10 | >=0 & <=100
	// Initial number of worker replicas
	initial_replicas: *0 | >=0 & <=100
	// Worker node template configuration
	worker_template: {
		// CPU cores per worker
		cores: >=2 & <=128
		// Memory in MB per worker
		memory: >=2048 & <=524288
		// Disk size in GB per worker
		disk_size: >=20 & <=10000
		// Talos schematic ID
		schematic_id: =~"^[a-z0-9]{64}$"
	}
}

#Node: {
	// Node hostname
	name: string & =~"^[a-z0-9-]+$"
	// IP address
	address: net.IPv4
	// MAC address
	mac_addr: =~"^([0-9a-f]{2}[:]){5}([0-9a-f]{2})$"
	// Talos schematic ID from factory.talos.dev
	schematic_id: =~"^[a-z0-9]{64}$"
	// CPU cores
	cores: >=2 & <=128
	// Memory in MB
	memory: >=2048 & <=524288
	// Disk size in GB
	disk_size: >=20 & <=10000
	// Optional: SecureBoot
	secureboot?: bool
	// Optional: Disk encryption
	encrypt_disk?: bool
	// Optional: Kernel modules
	kernel_modules?: [...string]
}

#Config
