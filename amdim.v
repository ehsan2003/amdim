//    This program is free software: you can redistribute it and/or modify
//    it under the terms of the GNU General Public License as published by
//    the Free Software Foundation, either version 3 of the License, or
//    (at your option) any later version.
//
//    This program is distributed in the hope that it will be useful,
//    but WITHOUT ANY WARRANTY; without even the implied warranty of
//    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//    GNU General Public License for more details.
//
//    You should have received a copy of the GNU General Public License
//    along with this program.  If not, see <https://www.gnu.org/licenses/>.

// to compile v -prod -cflags "-O3 -march=native" -o amdim amdim.v && strip -s amdim (prealloc and autofree are* danger)

module main

import os
import strconv
import time

const target_ips = ['dcn', 'dce']
const state_file = '/tmp/amdim_base_value'

fn main() {
	if _unlikely_(os.execute('which umr').exit_code != 0) {
        println('Error: "umr" is not installed.')
        return
    }

	mut threads := []thread{}
	if _unlikely_(os.geteuid() != 0) {
		println('Error: Run with sudo')
		return
	}
	if _unlikely_(os.args.len < 4) {
		println('Usage: sudo ./amdim <+/-><hex_offset> loopmode(0,1,2) eyecare(0,1)')
		return
	}

	input_str := os.args[1].trim_space()
	mut is_negative := false
	mut clean_hex := input_str

	if input_str.starts_with('-') {
		is_negative = true
		clean_hex = input_str[1..]
	} else if input_str.starts_with('+') {
		clean_hex = input_str[1..]
	}
	
	clean_hex = clean_hex.replace('0x', '')
	offset_val := strconv.parse_uint(clean_hex, 16, 32) or {
		println('Error: Invalid hex value')
		return
	}

	ip_block := find_gpu_ip() or {
		println('Error: $err')
		return
	}

	mut base_val := u64(0)

	if os.exists(state_file) {
		saved_content := os.read_file(state_file) or { '' }
		base_val = strconv.parse_uint(saved_content, 10, 64) or { 0 }
	}

	if base_val == 0 {
		_, hw_val := find_active_reg(ip_block) or {
			println('Error: $err')
			return
		}
		base_val = hw_val
		os.write_file(state_file, base_val.str()) or { }
	}

	mask := base_val & 0xFFFF0000
	base_brightness := base_val & 0x0000FFFF
	
	mut new_brightness := u64(0)
	if is_negative {
		if base_brightness > offset_val {
			new_brightness = base_brightness - offset_val
		} else {
			new_brightness = 0
		}
	} else {
		new_brightness = base_brightness + offset_val
		if new_brightness > 0xFFFF {
			new_brightness = 0xFFFF
		}
	}

	final_val := mask | new_brightness
	
	op_sign := if is_negative { '-' } else { '+' }
	println('Applying: Base(0x${base_brightness.hex()}) ${op_sign} Offset(0x${offset_val.hex()}) = 0x${final_val.hex()}')

	reg_name, _ := find_active_reg(ip_block) or {
		println('Error: $err')
		return
	}

	cmd := 'umr -w ${ip_block}.${reg_name} 0x${final_val.hex()}'
	
	if _likely_(os.execute(cmd).exit_code == 0) {
		if os.args[3] == "1" {
			threads << spawn deblue(ip_block, 1)
		} else {
			threads << spawn deblue(ip_block, 0)
		}
		
		if os.args[2] == "1" {
			threads << spawn deabm(ip_block)
		} else if os.args[2] == "2" {
			threads << spawn deabm(ip_block)
			for {
				time.sleep(1500 * time.millisecond)
				_, curr_check := find_active_reg(ip_block) or { continue }
				if _unlikely_(curr_check != final_val) {
					threads << spawn deabm(ip_block)
					if os.args[3] == "1" {
						threads << spawn deblue(ip_block, 1)
					}
					os.execute(cmd)
				}
			}
		}
	} else {
		println('Error: Failed to write to hardware')
	}
	threads.wait()
}

@[inline]
fn deabm(ip_block string) {
	mut threads := []thread{}
    os.execute('umr -w ${ip_block}.mmBL1_PWM_ABM_CNTL 0')
    os.execute('umr -w ${ip_block}.mmDC_ABM1_CNTL 0')
    for i in 0..6 {
        threads << spawn fn (id int, ip string) {
            os.execute('umr -w ${ip}.mmFMT${id}_FMT_BIT_DEPTH_CONTROL 2')
        }(i, ip_block)
    }
    for i in 0 .. 4 {
        threads << spawn fn (id int, ip string) {
            os.execute('umr -w ${ip}.mmCNVC_CFG${id}_FORMAT_CONTROL 0')
            os.execute('umr -w ${ip}.mmCNVC_CFG${id}_FCNV_FP_BIAS_R 0')
            os.execute('umr -w ${ip}.mmCNVC_CFG${id}_FCNV_FP_BIAS_G 0')
            os.execute('umr -w ${ip}.mmCNVC_CFG${id}_FCNV_FP_BIAS_B 0')
        }(i, ip_block)
    }
    os.execute('umr -w ${ip_block}.mmODM_MEM_PWR_CTRL 0')
    os.execute('umr -w ${ip_block}.mmODM_MEM_PWR_CTRL2 0')
    os.execute('umr -w ${ip_block}.mmODM_MEM_PWR_CTRL3 0')

    for i in 0 .. 6 {
        threads << spawn fn (id int, ip string) {
            os.execute('umr -w ${ip}.mmODM${id}_OPTC_DATA_FORMAT_CONTROL 0')
        }(i, ip_block)
    }
    threads.wait()
}

@[inline]
fn deblue(ip_block string, ena int) {
	mut threads := []thread{}
    mut green_hex := '00001000'
    mut blue_hex  := '00001000'
    mut ctrl_val  := '0'
    if ena != 0 {
        green_hex = '00000FFF'
        blue_hex  = '00000000'
        ctrl_val  = '1'
    }
    os.execute('umr -w ${ip_block}.mmOTG0_OTG_MASTER_UPDATE_LOCK 1')
    for i in 0 .. 4 {
		threads << spawn fn (id int, ip string, green_hex string, blue_hex string, ctrl_val string) {
			os.execute('umr -w ${ip}.mmCM${id}_CM_GAMUT_REMAP_CONTROL ${ctrl_val}')
			os.execute('umr -w ${ip}.mmCM${id}_CM_GAMUT_REMAP_C21_C22 0x${green_hex}')
			os.execute('umr -w ${ip}.mmCM${id}_CM_GAMUT_REMAP_C33_C34 0x${blue_hex}')
		}(i, ip_block, green_hex, blue_hex, ctrl_val)
    }
    os.execute('umr -w ${ip_block}.mmOTG0_OTG_MASTER_UPDATE_LOCK 0')
	threads.wait()
}

@[inline]
fn find_gpu_ip() !string {
	res := os.execute('umr -lb')
	if _unlikely_(res.exit_code != 0) { return error('umr failed') }
	for line in res.output.split('\n') {
		t := line.trim_space()
		for ip in target_ips {
			if t.contains('.$ip') { return t.split(' ')[0] }
		}
	}
	return error('No supported GPU block found')
}

@[inline]
fn find_active_reg(ip string) !(string, u64) {
	res := os.execute('umr --list-regs $ip')
	if _unlikely_(res.exit_code != 0) { return error('Failed to list regs') }
	mut best_reg := ''
	mut best_val := u64(0)
	for line in res.output.split('\n') {
		if (line.contains('PWM_CNTL') || line.contains('PWM_USER_LEVEL')) &&
		   !line.contains('PERIOD') && !line.contains('lock') && !line.contains('ABM') {
			parts := line.split('=>')
			if parts.len > 0 {
				path := parts[0].split('.')
				if path.len >= 3 {
					reg := path[2].split('(')[0].trim_space()
					read := os.execute('umr -r ${ip}.${reg}')
					if read.exit_code == 0 {
						for l in read.output.split('\n') {
							if l.contains('=>') {
								val_parts := l.split('=>')
								if val_parts.len > 1 {
									val := strconv.parse_uint(val_parts[1].trim_space().replace('0x', ''), 16, 64) or { 0 }
									if val > 0xFFFF { return reg, val }
									if val > 0 { best_reg = reg; best_val = val }
								}
							}
						}
					}
				}
			}
		}
	}
	if best_reg != '' { return best_reg, best_val }
	return error('No active PWM register found')
}
