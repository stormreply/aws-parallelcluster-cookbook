# frozen_string_literal: true

#
# Copyright:: 2023 Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License").
# You may not use this file except in compliance with the License.
# A copy of the License is located at
#
# http://aws.amazon.com/apache2.0/
#
# or in the "LICENSE.txt" file accompanying this file.
# This file is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied.
# See the License for the specific language governing permissions and limitations under the License.

# This is the local system directory at which we want to mount the EFS mount point
property :shared_dir_array, Array, required: %i(mount unmount)
property :efs_fs_id_array, Array, required: %i(mount unmount)
property :efs_encryption_in_transit_array, Array, required: false
property :efs_iam_authorization_array, Array, required: false
# This is the mount point on the EFS itself, as opposed to the local system directory, defaults to "/"
property :efs_mount_point_array, Array, required: false
property :efs_unmount_forced_array, Array, required: false

action :mount do
  return if on_docker?
  efs_shared_dir_array = new_resource.shared_dir_array.dup
  efs_fs_id_array = new_resource.efs_fs_id_array.dup
  efs_encryption_in_transit_array = new_resource.efs_encryption_in_transit_array.dup
  efs_iam_authorization_array = new_resource.efs_iam_authorization_array.dup
  efs_mount_point_array = new_resource.efs_mount_point_array.dup

  efs_fs_id_array.each_with_index do |efs_fs_id, index|
    efs_shared_dir = efs_shared_dir_array[index]
    efs_encryption_in_transit = efs_encryption_in_transit_array[index] unless efs_encryption_in_transit_array.nil?
    efs_iam_authorization = efs_iam_authorization_array[index] unless efs_iam_authorization_array.nil?

    # Path needs to be fully qualified, for example "shared/temp" becomes "/shared/temp"
    efs_shared_dir = "/#{efs_shared_dir}" unless efs_shared_dir.start_with?('/')

    # See reference of mount options: https://docs.aws.amazon.com/efs/latest/ug/automount-with-efs-mount-helper.html
    mount_options = "_netdev,noresvport"
    if efs_encryption_in_transit == "true"
      mount_options += ",tls"
      if efs_iam_authorization == "true"
        mount_options += ",iam"
      end
    end
    mount_point = efs_mount_point_array.nil? ? "/" : efs_mount_point_array[index]

    # Create the EFS shared directory
    directory efs_shared_dir do
      owner 'root'
      group 'root'
      mode '1777'
      recursive true
      action :create
    end unless ::File.directory?(efs_shared_dir)

    # Mount EFS over NFS
    mount efs_shared_dir do
      device "#{efs_fs_id}:#{mount_point}"
      fstype 'efs'
      options mount_options
      dump 0
      pass 0
      action :mount
      retries 10
      retry_delay 60 # increase to 60s because it takes about 5 minutes for a  managed EFS to be ready to mount after creation complete
      not_if "mount | grep ' #{efs_shared_dir} '"
    end

    # Enable the mount dir
    mount efs_shared_dir do
      device "#{efs_fs_id}:#{mount_point}"
      fstype 'efs'
      options mount_options
      dump 0
      pass 0
      action :enable
      retries 10
      retry_delay 6
      only_if "mount | grep ' #{efs_shared_dir} '"
    end

    # Make sure EFS shared directory permissions are correct
    directory "change permissions for #{efs_shared_dir}" do
      path efs_shared_dir
      owner 'root'
      group 'root'
      mode '1777'
      only_if { node['cluster']['node_type'] == "HeadNode" }
    end
  end
end

action :unmount do
  return if on_docker?
  efs_shared_dir_array = new_resource.shared_dir_array.dup
  efs_shared_dir_array.each do |efs_shared_dir|
    # Path needs to be fully qualified, for example "shared/temp" becomes "/shared/temp"
    efs_shared_dir = "/#{efs_shared_dir}" unless efs_shared_dir.start_with?('/')
    # Unmount EFS
    file_utils "check active processes on #{efs_shared_dir}" do
      file efs_shared_dir
      action :check_active_processes
    end
    execute 'unmount efs' do
      command "umount -fl #{efs_shared_dir}"
      retries 10
      retry_delay 6
      timeout 60
      only_if "mount | grep ' #{efs_shared_dir} '"
    end
    # remove volume from fstab
    delete_lines "remove volume #{efs_shared_dir} from /etc/fstab" do
      path "/etc/fstab"
      pattern " #{efs_shared_dir} "
    end
    # Delete the EFS shared directory
    directory efs_shared_dir do
      owner 'root'
      group 'root'
      mode '1777'
      recursive false
      action :delete
      only_if { Dir.exist?(efs_shared_dir.to_s) && Dir.empty?(efs_shared_dir.to_s) }
    end
  end
end
