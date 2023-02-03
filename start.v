module main

import threefoldtech.farmerbot.factory

import flag
import log
import os

const default_data_dir = os.dir(@FILE) + '/example_data'

fn main() {
	mut fp := flag.new_flag_parser(os.args)
	fp.application('Welcome to the farmerbot. The farmerbot is a service that a farmer can run allowing him to automatically manage the nodes of his farm.')
	fp.limit_free_args(0, 0)!
	fp.description('')
	fp.skip_executable()
	directory := fp.string('config_dir', `c`, '${default_data_dir}', 'The directory containing the markup definition files with the configuration of the nodes.')
	debug_log := fp.bool('debug', 0, false, 'By setting this flag the farmerbot will print debug logs too.')
	_ := fp.finalize() or {
		eprintln(err)
		println(fp.usage())
		return
	}
	// TODO add arguments
	mut f := factory.new(directory, if debug_log { log.Level.debug } else { log.Level.info }) or {
		exit(1)
	}
	
	f.run() or { 
		exit(1)
	}
}
