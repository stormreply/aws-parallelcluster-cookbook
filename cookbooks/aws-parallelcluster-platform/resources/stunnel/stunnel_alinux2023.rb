# frozen_string_literal: true
#
# Copyright:: 2024 Amazon.com, Inc. or its affiliates. All Rights Reserved.
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

provides :stunnel, platform: 'amazon' do |node|
  node['platform_version'].to_i == 2023
end

use 'partial/_common'
use 'partial/_setup'

action_class do
  def dependencies
    # tcp_wrappers-devel has been deprecated in RHEL7 and deleted in RHEL8, however it is
    # an optional requirement not strictly necessary for either stunnel or efs-utils
    %w(openssl-devel)
  end
end
