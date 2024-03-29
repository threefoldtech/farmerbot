module manager

import freeflowuniverse.baobab.actions
import freeflowuniverse.baobab.client
import freeflowuniverse.baobab.jobs
import freeflowuniverse.crystallib.params
import threefoldtech.farmerbot.system { Node }
import log
import time

const (
	node_manager_prefix = '[NODEMANAGER]'
)

[heap]
pub struct NodeManager {
	name string = 'farmerbot.nodemanager'
pub mut:
	client  client.Client
	db      &system.DB
	logger  &log.Logger
	tfchain &system.ITfChain
	zos     &system.IZos
}

pub fn (mut n NodeManager) on_started() {
}

pub fn (mut n NodeManager) on_stop() {
}

pub fn (mut n NodeManager) init(mut action actions.Action) ! {
	if action.name == system.action_node_define {
		n.data_set(mut action)!
	} else {
		n.logger.warn('${manager.node_manager_prefix} Unknown action ${action.name}')
	}
}

pub fn (mut n NodeManager) execute(mut job jobs.ActionJob) ! {
	if job.action == system.job_node_find {
		n.find_node(mut job)!
	}
}

pub fn (mut n NodeManager) update() {
}

fn (mut n NodeManager) data_set(mut action actions.Action) ! {
	n.logger.info('${manager.node_manager_prefix} Executing action: DATA_SET')
	n.logger.debug('${manager.node_manager_prefix} ${action}')

	twin_id := action.params.get_u32('twinid')!
	cpu_overprovision := action.params.get_u8_default('cpuoverprovision', n.db.default_cpu_overprovision)!
	if cpu_overprovision < 1 || cpu_overprovision > 4 {
		return error('cpuoverprovision should be a value between 1 and 4')
	}
	mut node := Node{
		id: action.params.get_u32('id')!
		twin_id: twin_id
		description: action.params.get_default('description', '')!
		resources: system.ConsumableResources{
			overprovision_cpu: cpu_overprovision
			total: system.Capacity{
				cru: action.params.get_u64_default('cru', 0)!
				sru: action.params.get_storagecapacity_in_bytes_default('sru', 0)!
				mru: action.params.get_storagecapacity_in_bytes_default('mru', 0)!
				hru: action.params.get_storagecapacity_in_bytes_default('hru', 0)!
			}
		}
		public_config: action.params.get_default_false('public_config')
		dedicated: action.params.get_default_false('dedicated')
		certified: action.params.get_default_false('certified')
		powerstate: .on
		never_shutdown: action.params.get_default_false('never_shutdown')
	}

	n.db.nodes[node.id] = &node
}

fn (mut n NodeManager) find_node(mut job jobs.ActionJob) ! {
	n.logger.info('${manager.node_manager_prefix} Executing job: FIND_NODE')

	mut has_gpus := job.args.get_u8_default('has_gpus', 0)!
	gpu_vendors := job.args.get_list_default('gpu_vendors', []string{}) or {
		return error('Invalid list gpu_vendors: ${err}')
	}
	gpu_devices := job.args.get_list_default('gpu_devices', []string{}) or {
		return error('Invalid list gpu_devices: ${err}')
	}
	certified := job.args.get_default_false('certified')
	public_config := job.args.get_default_false('public_config')
	public_ips := job.args.get_u32_default('public_ips', 0)!
	dedicated := job.args.get_default_false('dedicated')
	node_exclude := job.args.get_list_u32_default('node_exclude', []u32{})
	required_capacity := system.Capacity{
		hru: job.args.get_storagecapacity_in_bytes_default('required_hru', 0)!
		sru: job.args.get_storagecapacity_in_bytes_default('required_sru', 0)!
		mru: job.args.get_storagecapacity_in_bytes_default('required_mru', 0)!
		cru: job.args.get_u64_default('required_cru', 0)!
	}

	if (gpu_vendors.len > 0 || gpu_devices.len > 0) && has_gpus == 0 {
		// at least one gpu in case the user didn't provide the amount
		has_gpus = 1
	}

	n.logger.debug('${manager.node_manager_prefix} Requirements:\ncertified:${certified}\npublic_config:${public_config}\npublic_ips:${public_ips}\ndedicated:${dedicated}\nnode_exclude:${node_exclude}\nrequired_capacity:${required_capacity}\nhas_gpus:${has_gpus}\ngpu_vendor:${gpu_vendors}\ngpu_device:${gpu_devices}')

	if public_ips > 0 {
		mut public_ips_used_by_nodes := u64(0)
		for node in n.db.nodes.values() {
			public_ips_used_by_nodes += node.public_ips_used
		}
		if public_ips_used_by_nodes + public_ips > n.db.farm.public_ips {
			return error('Not enough public ips available')
		}
	}

	mut possible_nodes := []&Node{}
	for node in n.db.nodes.values() {
		if has_gpus > 0 {
			mut gpus := node.gpus.clone()
			if gpu_vendors.len > 0 {
				gpus = gpus.filter(it.vendor.contains_any_substr(gpu_vendors))
			}
			if gpu_devices.len > 0 {
				gpus = gpus.filter(it.device.contains_any_substr(gpu_devices))
			}
			if gpus.len < has_gpus {
				continue
			}
		}
		if certified && !node.certified {
			continue
		}
		if public_config && !node.public_config {
			continue
		}
		if node.has_active_rent_contract {
			continue
		}
		if dedicated {
			if !node.dedicated || !node.is_unused() {
				continue
			}
		} else {
			if node.dedicated && required_capacity != node.resources.total {
				continue
			}
		}
		if node.id in node_exclude {
			continue
		}
		if !node.can_claim_resources(required_capacity) {
			continue
		}
		possible_nodes << node
	}

	// Sort the nodes on power state (the ones that are ON first then wakingup, off, shuttingdown)
	possible_nodes.sort_with_compare(fn (a &&Node, b &&Node) int {
		if a.powerstate == b.powerstate {
			return 0
		} else if u8(a.powerstate) < u8(b.powerstate) {
			return -1
		} else {
			return 1
		}
	})

	if possible_nodes.len == 0 {
		return error('Could not find a suitable node')
	}

	mut node := possible_nodes[0]
	n.logger.debug('${manager.node_manager_prefix} Found a node: ${node}')

	// claim the resources until next update of the data
	// add a timeout (30 minutes)
	node.timeout_claimed_resources = time.now().add(time.minute * 30)
	if dedicated || has_gpus > 0 {
		// claim all capacity
		node.claim_resources(node.resources.total)
	} else {
		node.claim_resources(required_capacity)
	}

	// claim public ips until next update of the data
	if public_ips > 0 {
		node.public_ips_used += public_ips
	}

	job.result.kwarg_add('nodeid', '${node.id}')

	// power on the node if it is down or if it is shutting down
	if node.powerstate == system.PowerState.off || node.powerstate == system.PowerState.shuttingdown {
		_ := n.client.job_new_schedule(
			twinid: n.client.twinid
			action: system.job_power_on
			args: job.result
			actionsource: system.job_node_find
		)!
	}
}
