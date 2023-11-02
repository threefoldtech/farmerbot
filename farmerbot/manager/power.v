module manager

import freeflowuniverse.baobab.actions
import freeflowuniverse.baobab.client
import freeflowuniverse.baobab.jobs
import freeflowuniverse.crystallib.params { Params }
import threefoldtech.farmerbot.system { Capacity, ITfChain, IZos, Node }
import log
import math
import rand
import time

const (
	power_manager_prefix           = '[POWERMANAGER]'
	periodic_wakeup_duration       = time.minute * 30
	default_random_wakeups_a_month = 10
	timeout_power_job              = 10.0 // timeout is in seconds
)

[heap]
pub struct PowerManager {
	name string = 'farmerbot.powermanager'
mut:
	client                 client.Client
	db                     &system.DB
	logger                 &log.Logger
	tfchain                &ITfChain
	zos                    &IZos
	random_wakeups_a_month int = manager.default_random_wakeups_a_month
}

pub fn (mut p PowerManager) on_started() {
	p.logger.info('${manager.power_manager_prefix} Startup proces: powering on all nodes that are down.')
	p.poweron_all_nodes()
}

pub fn (mut p PowerManager) on_stop() {
	p.logger.info('${manager.power_manager_prefix} Shutdown proces: powering on all nodes that are down.')
	p.poweron_all_nodes()
}

pub fn (mut p PowerManager) init(mut action actions.Action) ! {
	if action.name == system.action_power_configure {
		p.configure(mut action)!
	} else {
		p.logger.warn('${manager.power_manager_prefix} Unknown action ${action.name}')
	}
}

pub fn (mut p PowerManager) execute(mut job jobs.ActionJob) ! {
	if job.src_twinid == p.client.twinid || job.src_twinid == 0 {
		match job.action {
			system.job_power_on {
				p.poweron(mut job)!
			}
			system.job_power_off {
				p.poweroff(mut job)!
			}
			else {
				return error('Unknown action ${job.action}')
			}
		}
	}
}

pub fn (mut p PowerManager) update() {
	p.periodic_wakeup()
	p.power_management()
}

fn (mut p PowerManager) poweron_all_nodes() {
	for mut node in p.db.nodes.values() {
		p.schedule_power_job(node.id, .on) or {
			p.logger.error('${manager.power_manager_prefix} Job to power on node ${node.id} failed: ${err}')
		}
	}
}

fn (mut p PowerManager) periodic_wakeup() {
	// convert time to utc to avoid daylight saving issues
	now := time.now().local_to_utc()
	today := time.new_time(year: now.year, month: now.month, day: now.day)
	periodic_wakeup_start := today.add(p.db.periodic_wakeup_start)
	mut amount_wakeup_calls := 0
	amount_of_nodes := p.db.nodes.len
	rwam := int(p.random_wakeups_a_month)
	pwl := int(p.db.periodic_wakeup_limit)
	for mut node in p.db.nodes.values().filter(it.powerstate == .off) {
		if now.day == 1 && now.hour == 1 && now.minute >= 0 && now.minute < 5 {
			node.times_random_wakeups = 0
		}
		if periodic_wakeup_start <= now && node.last_time_awake.local_to_utc() < periodic_wakeup_start {
			// Fixed periodic wakeup (once a day)
			// we wakeup the node if the periodic wakeup start time has started and only if the last time the node was awake
			// was before the periodic wakeup start of that day
			p.logger.info('${manager.power_manager_prefix} Periodic wakeup for node ${node.id}')
			p.schedule_power_job(node.id, .on) or {
				p.logger.error('${manager.power_manager_prefix} Job to power on node ${node.id} failed: ${err}')
				continue
			}
			amount_wakeup_calls += 1
			if amount_wakeup_calls >= p.db.periodic_wakeup_limit {
				// reboot X nodes at a time others will be rebooted 5 min later
				break
			}
		} else if node.times_random_wakeups < p.random_wakeups_a_month
			&& rand.int31() % ((8460 - (rwam * 6) - (rwam * (amount_of_nodes - 1)) / math.min(pwl, amount_of_nodes)) / rwam) == 0 {
			// Random periodic wakeup (10 times a month on average if the node is almost always down)
			// we execute this code every 5 minutes => 288 times a day => 8640 times a month on average (30 days)
			// but we have 30 minutues of periodic wakeup every day (6 times we do not go through this code) => so 282 times a day => 8460 times a month on average (30 days)
			// as we do a random wakeup 10 times a month we know the node will be on for 30 minutes 10 times a month so we can substract 6 times the amount of random wakeups a month
			// we also do not go through the code if we have woken up too many nodes at once => substract (10 * (n-1))/min(periodic_wakeup_limit, amount_of_nodes) from 8460
			// now we can divide that by 10 and randomly generate a number in that range, if it's 0 we do the random wakeup
			p.logger.info('${manager.power_manager_prefix} Random wakeup for node ${node.id}')
			p.schedule_power_job(node.id, .on) or {
				p.logger.error('${manager.power_manager_prefix} Job to power on node ${node.id} failed: ${err}')
				continue
			}
			amount_wakeup_calls += 1
			node.times_random_wakeups += 1
			if amount_wakeup_calls >= p.db.periodic_wakeup_limit {
				// reboot X nodes at a time others will be rebooted 5 min later
				break
			}
		}
	}
}

fn (mut p PowerManager) power_management() {
	used_resources, total_resources := p.calculate_resource_usage()
	if total_resources == 0 {
		return
	}
	mut resource_usage := 100 * used_resources / total_resources
	if resource_usage >= p.db.wake_up_threshold {
		p.resource_usage_too_low(resource_usage)
	} else {
		p.resource_usage_too_high(used_resources, total_resources)
	}
}

fn (mut p PowerManager) resource_usage_too_low(resource_usage u64) {
	sleeping_nodes := p.db.nodes.values().filter(it.powerstate == .off)
	if sleeping_nodes.len > 0 {
		node := sleeping_nodes.first()
		p.logger.info('${manager.power_manager_prefix} Too much resource usage: ${resource_usage}. Turning on node ${node.id}')
		p.schedule_power_job(node.id, .on) or {
			p.logger.error('${manager.power_manager_prefix} Job to power on node ${node.id} failed: ${err}')
		}
	}
}

fn (mut p PowerManager) resource_usage_too_high(used_resources u64, total_resources u64) {
	nodes_on := p.db.nodes.values().filter(it.powerstate == .on)
	// nodes with public config can't be shutdown
	// Do not shutdown a node that just came up (give it some time)
	nodes_allowed_to_shutdown := nodes_on.filter(it.is_unused() && !it.public_config
		&& !it.never_shutdown
		&& time.since(it.last_time_powerstate_changed) >= manager.periodic_wakeup_duration)

	if nodes_on.len > 1 {
		// shutdown a node if there is more then 1 unused node (aka keep at least one node online)
		mut new_used_resources := used_resources
		mut new_total_resources := total_resources
		mut nodes_left_online := nodes_on.len
		for node in nodes_allowed_to_shutdown {
			if nodes_left_online == 1 {
				break
			}
			nodes_left_online -= 1
			new_used_resources -= node.resources.used.hru + node.resources.used.sru +
				node.resources.used.mru + node.resources.used.cru
			new_total_resources -= node.resources.total.hru + node.resources.total.sru +
				node.resources.total.mru + node.resources.total.cru
			if new_total_resources == 0 {
				break
			}
			new_resource_usage := 100 * new_used_resources / new_total_resources
			if new_resource_usage < p.db.wake_up_threshold {
				// we need to keep the resource percentage lower then the threshold
				p.logger.info('${manager.power_manager_prefix} Resource usage too low: ${new_resource_usage}. Turning off unused node ${node.id}')
				p.schedule_power_job(node.id, .off) or {
					// Something went wrong so undo calculation
					nodes_left_online += 1
					new_used_resources += node.resources.used.hru + node.resources.used.sru +
						node.resources.used.mru + node.resources.used.cru
					new_total_resources += node.resources.total.hru + node.resources.total.sru +
						node.resources.total.mru + node.resources.total.cru
					p.logger.error('${manager.power_manager_prefix} Job to power off node ${node.id} failed: ${err}')
				}
			}
		}
	} else {
		p.logger.debug('${manager.power_manager_prefix} Nothing to shutdown.')
	}
}

fn (mut p PowerManager) calculate_resource_usage() (u64, u64) {
	mut used_resources := Capacity{}
	mut total_resources := Capacity{}

	for node in p.db.nodes.values().filter(it.powerstate == .on || it.powerstate == .wakingup) {
		if node.has_active_rent_contract {
			used_resources.add(node.resources.total)
		} else {
			used_resources.add(node.resources.used)
		}
		total_resources.add(node.resources.total)
	}

	return used_resources.cru + used_resources.hru + used_resources.mru + used_resources.sru,
		total_resources.cru + total_resources.hru + total_resources.mru + total_resources.sru
}

fn (mut p PowerManager) nodeid_from_args(job &jobs.ActionJob) !&Node {
	nodeid := job.args.get_u32('nodeid') or {
		return error('The argument nodeid is required in order to power off a node')
	}
	return p.db.get_node(nodeid)!
}

fn (mut p PowerManager) poweron(mut job jobs.ActionJob) ! {
	mut node := p.nodeid_from_args(&job)!
	p.logger.info('${manager.power_manager_prefix} Executing job: POWERON ${node.id}')

	if node.powerstate == .wakingup || node.powerstate == .on {
		// nothing to do
		return
	}

	powerstate := node.powerstate
	last_time_powerstate_changed := node.last_time_powerstate_changed

	node.powerstate = .wakingup
	node.last_time_powerstate_changed = time.now()

	p.tfchain.set_node_power(node.id, .on) or {
		node.powerstate = powerstate
		node.last_time_powerstate_changed = last_time_powerstate_changed
		return error('${err}')
	}
}

fn (mut p PowerManager) poweroff(mut job jobs.ActionJob) ! {
	mut node := p.nodeid_from_args(&job)!
	p.logger.info('${manager.power_manager_prefix} Executing job: POWEROFF ${node.id}')

	if node.powerstate == .shuttingdown || node.powerstate == .off {
		// nothing to do
		return
	}
	if node.public_config {
		return error('Cannot power off node, node has public config.')
	}
	if node.never_shutdown {
		return error('Cannot power off node, node is configured to never be shutdown.')
	}
	if p.db.nodes.values().filter(it.powerstate == .on).len < 2 {
		return error('Cannot power off node, at least one node should be on in the farm.')
	}

	powerstate := node.powerstate
	last_time_powerstate_changed := node.last_time_powerstate_changed

	node.powerstate = .shuttingdown
	node.last_time_powerstate_changed = time.now()

	p.tfchain.set_node_power(node.id, .off) or {
		node.powerstate = powerstate
		node.last_time_powerstate_changed = last_time_powerstate_changed
		return error('${err}')
	}
}

fn (mut p PowerManager) schedule_power_job(nodeid u32, powerstate system.PowerState) ! {
	mut args := Params{}
	args.kwarg_add('nodeid', '${nodeid}')
	job := p.client.job_new_wait(
		twinid: p.client.twinid
		action: if powerstate == .on { system.job_power_on } else { system.job_power_off }
		args: args
		actionsource: ''
		timeout: manager.timeout_power_job
	)!
	if job.state == .error {
		return error('${job.error}')
	}
}

fn (mut p PowerManager) configure(mut action actions.Action) ! {
	mut wake_up_threshold := action.params.get_u8_default('wake_up_threshold', system.default_wakeup_threshold)!
	if wake_up_threshold < system.min_wakeup_threshold
		|| wake_up_threshold > system.max_wakeup_threshold {
		wake_up_threshold = if wake_up_threshold < system.min_wakeup_threshold {
			u8(system.min_wakeup_threshold)
		} else {
			u8(system.max_wakeup_threshold)
		}
		p.logger.warn('${manager.power_manager_prefix} The setting wake_up_threshold should be in the range [${system.min_wakeup_threshold}, ${system.max_wakeup_threshold}]')
	}

	periodic_wakeup_start := action.params.get_timestamp_default('periodic_wakeup', time.hour * time.now().hour)!

	mut periodic_wakeup_limit := action.params.get_u8_default('periodic_wakeup_limit',
		system.default_periodic_wakeup_limit)!
	if periodic_wakeup_limit == 0 {
		periodic_wakeup_limit = system.default_periodic_wakeup_limit
		p.logger.warn('${manager.power_manager_prefix} The setting periodic_wakeup_limit should be greater then 0!')
	}
	periodic_wakeup_start_utc = convert_to_utc(periodic_wakeup_start)
	p.db.wake_up_threshold = wake_up_threshold
	p.db.periodic_wakeup_start = periodic_wakeup_start_utc
	p.db.periodic_wakeup_limit = periodic_wakeup_limit
}


fn convert_to_utc(d Duration) Duration{
	now := time.now()
	today := time.new_time(year: now.year, month: now.month, day: now.day)
	daily_wakeup := today.add(d).local_to_utc()
	return Duration(daily_wakeup.hour * time.hour + daily_wakeup.minute * time.minute)
}
