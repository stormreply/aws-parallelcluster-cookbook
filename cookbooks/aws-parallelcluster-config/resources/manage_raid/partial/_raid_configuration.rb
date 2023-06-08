# frozen_string_literal: true

# Copyright:: 2022 Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License"). You may not use this file except in compliance
# with the License. A copy of the License is located at http://aws.amazon.com/apache2.0/
# or in the "LICENSE.txt" file accompanying this file. This file is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
# OR CONDITIONS OF ANY KIND, express or implied. See the License for the specific language governing permissions and
# limitations under the License.

unified_mode true

property :raid_shared_dir, String, required: true
property :raid_type, [String, Integer], required: %i(mount)
property :raid_vol_array, Array, required: true

action :mount do
  raid_vol_array = new_resource.raid_vol_array.dup
  raid_shared_dir = new_resource.raid_shared_dir.dup
  # Parse and determine RAID type (cast into integer)
  raid_type = new_resource.raid_type.dup.strip.to_i

  # Attach each volume
  raid_dev_path = []
  raid_vol_array.each_with_index do |volumeid, index|
    raid_dev_path[index] = "/dev/disk/by-ebs-volumeid/#{volumeid}"

    # Attach RAID EBS volume
    volume "attach raid volume #{index}" do
      volume_id volumeid
      action :attach
    end
  end

  raid_dev = "/dev/md0"
  mdadm "MY_RAID" do
    raid_device raid_dev
    level raid_type
    # Raid superblock documentation https://raid.wiki.kernel.org/index.php/RAID_superblock_formats
    metadata raid_superblock_version
    devices raid_dev_path
  end

  # Wait for RAID to initialize
  ruby_block "sleeping_for_raid_block" do
    block do
      wait_for_block_dev(raid_dev)
    end
    action :nothing
    subscribes :run, "mdadm[MY_RAID]", :immediately
  end

  # Setup RAID disk, create ext4 filesystem on RAID array
  execute "setup_raid_disk" do
    command "sudo mkfs.ext4 #{raid_dev}"
    action :nothing
    subscribes :run, "ruby_block[sleeping_for_raid_block]", :immediately
  end

  # Create a configuration file to contain the RAID info, so the RAID array is reassembled automatically on boot
  execute "create_raid_config" do
    command "sudo mdadm --detail --scan | sudo tee -a /etc/mdadm.conf"
    action :nothing
    subscribes :run, "execute[setup_raid_disk]", :immediately
  end

  volume "mount raid volume" do
    action :mount
    shared_dir raid_shared_dir
    device raid_dev
    fstype "ext4"
    options "defaults,nofail,_netdev"
    retries 10
    retry_delay 6
  end
end

action :export do
  return if on_docker?

  raid_shared_dir = new_resource.raid_shared_dir.dup
  volume "export volume #{raid_shared_dir}" do
    shared_dir raid_shared_dir
    action :export
  end
end

action :unmount do
  return if on_docker?

  raid_vol_array = new_resource.raid_vol_array.dup
  raid_shared_dir = new_resource.raid_shared_dir.dup

  volume "unmount raid volume" do
    shared_dir raid_shared_dir
    action :unmount
  end

  # Get disks that are part of the RAID group.
  raid_dev = "/dev/md0"
  devices_list = get_raid_devices(raid_dev)

  # Stop mdadm RAID device
  execute "Deactivate array, releasing all resources" do
    command "mdadm --stop #{raid_dev}"
  end

  # Remove the Superblocks
  execute "Erase the MD superblock from a device" do
    command "mdadm --zero-superblock #{devices_list}"
  end

  # Remove RAID from /etc/mdadm.conf
  delete_lines "Remove RAID from /etc/mdadm.conf" do
    path "/etc/mdadm.conf"
    pattern "ARRAY #{raid_dev} *"
  end

  # Detach each volume
  raid_vol_array.each_with_index do |volumeid, index|
    # Detach RAID EBS volume
    volume "detach raid volume #{index}" do
      volume_id volumeid
      action :detach
    end
  end
end

action :unexport do
  return if on_docker?
  raid_shared_dir = new_resource.raid_shared_dir.dup
  volume "unexport volume #{raid_shared_dir}" do
    shared_dir raid_shared_dir
    action :unexport
  end
end

action_class do
  def get_raid_devices(raid_dev)
    cmd = Mixlib::ShellOut.new("sudo mdadm -v --detail --scan #{raid_dev} | awk -F= '/^[ ]+devices/ {print $2}' | tr , ' '")
    cmd.run_command.stdout.strip
  end
end
