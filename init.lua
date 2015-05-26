-- Copyright 2015 Boundary, Inc.
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--    http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

local framework = require('framework')
local json = require('json')
local dns = require('dns')
local Plugin = framework.Plugin 
local WebRequestDataSource = framework.WebRequestDataSource
local notEmpty = framework.string.notEmpty
local auth = framework.util.auth

local params = framework.params
params.name = 'Boundary Plugin Couchbase'
params.version = '2.0'
params.tags = 'couchbase'
params.pollInterval = notEmpty(tonumber(params.pollInterval), 1000)
params.host = notEmpty(params.host, 'localhost')
params.port = notEmpty(params.port, '8091')
params.advanced_metrics = params.advanced_metrics or false

local options = {}
options.host = params.host
options.port = params.port
options.auth = auth(params.username, params.password)
options.path = '/pools/nodes'
--options.path = '/pools/default/buckets'
options.wait_for_end = true
local ds = WebRequestDataSource:new(options)

local function getNode(nodes, hostname)
  for _, node in ipairs(nodes) do
    if node.hostname == hostname then
      return node
    end
  end
end

-- 1. get /pools/nodes
-- 2. get /pools/default/buckets for a list of available buckets and save bucket.name
-- 3. get /pools/default/buckets/%s/nodes/%s/stats?zoom=minute for each bucket if advanced metrics is enabled.

local target
local plugin = Plugin:new(params, ds)
function plugin:onParseValues(data, extra)
  local cluster = json.parse(data)
  local result = {}

  result['COUCHBASE_RAM_QUOTA_TOTAL'] = cluster.storageTotals.ram.quotaTotalPerNode or 0
  result['COUCHBASE_RAM_QUOTA_USED'] = cluster.storageTotals.ram.quotaUsedPerNode or 0
  
  local node = getNode(cluster.nodes, target)
  if node then
    result['COUCHBASE_CPU_USAGE_RATE'] = node.systemStats.cpu_utilization_rate or 0
    result['COUCHBASE_RAM_SYSTEM_TOTAL'] = node.systemStats.mem_free or 0
    result['COUCHBASE_RAM_SYSTEM_FREE'] = node.systemStats.mem_total or 0
    result['COUCHBASE_SWAP_TOTAL'] = node.systemStats.swap_total or 0
    result['COUCHBASE_SWAP_USED'] = node.systemStats.swap_used or 0
    result['COUCHBASE_OPERATIONS'] = node.interestingStats.ops or 0
    result['COUCHBASE_DOCUMENTS_COUNT'] = node.interestingStats.curr_items or 0
    result['COUCHBASE_DOCUMENTS_SIZE'] = node.interestingStats.couch_docs_data_size or 0
    result['COUCHBASE_DOCUMENTS_SIZE_ON_DISK'] = node.interestingStats.couch_docs_actual_disk_size or 0
    result['COUCHBASE_VIEWS_SIZE'] = node.interestingStats.couch_views_data_size or 0
    result['COUCHBASE_VIEWS_SIZE_ON_DISK'] = node.interestingStats.couch_views_actual_disk_size or 0
  end
  
  -- Standard metrics
   return result
end

local function init(host)
  dns.resolve(host, function (failure, addresses)
    if failure then
      -- TODO: Emit critical event
      return
    end

    target = addresses[1] .. ':' .. params.port 
    plugin:run()
  end)
end

init(params.host)

--[[
--
-- Compile and print advanced metrics from given data.
--
local function produceAdvanced(stamp, cluster, buckets)
  function coalesce(sample)
    local result = 0
    for _, bucket in pairs(buckets) do
      local vector = bucket.op.samples[sample] or {}
      result = result + vector[#vector] or 0
    end
    return result
  end

  metric(stamp, 'COUCHBASE_DOCUMENTS_FRAGMENTATION',  coalesce('couch_docs_fragmentation'))
  metric(stamp, 'COUCHBASE_VIEWS_FRAGMENTATION',      coalesce('couch_views_fragmentation'))
  metric(stamp, 'COUCHBASE_VIEWS_OPERATIONS',         coalesce('couch_views_ops'))
  metric(stamp, 'COUCHBASE_DISK_COMMIT_TIME',         coalesce('avg_disk_commit_time'))
  metric(stamp, 'COUCHBASE_DISK_UPDATE_TIME',         coalesce('avg_disk_update_time'))
  metric(stamp, 'COUCHBASE_CAS_HITS',                 coalesce('cas_hits'))
  metric(stamp, 'COUCHBASE_CAS_MISSES',               coalesce('cas_misses'))
  metric(stamp, 'COUCHBASE_DISK_FETCHES',             coalesce('ep_bg_fetched'))
  metric(stamp, 'COUCHBASE_EVICTIONS',                coalesce('evictions'))
  metric(stamp, 'COUCHBASE_MISSES',                   coalesce('misses'))
  metric(stamp, 'COUCHBASE_XDCR_OPERATIONS',          coalesce('xdc_ops'))
  metric(stamp, 'COUCHBASE_REPLICATION_CHANGES_LEFT', coalesce('replication_changes_left'))
  metric(stamp, 'COUCHBASE_MAJOR_FAULTS',             coalesce('major_faults'))
  metric(stamp, 'COUCHBASE_MINOR_FAULTS',             coalesce('minor_faults'))
  metric(stamp, 'COUCHBASE_PAGE_FAULTS',              coalesce('page_faults'))

  local selectedBucket = buckets[next(buckets)]
  local curr_connections = selectedBucket.op.samples.curr_connections
  metric(stamp, 'COUCHBASE_ACTIVE_CONNECTIONS',       curr_connections[#curr_connections] or 0)
end

--
-- Produce metrics.
--
local function poll()

  local stamp   = os.time()
  local cluster
  local buckets = {}
  local remain  = 1 + (_advancedMetrics and #_buckets or 0)
  local failed  = false

  function produce()
    if remain > 0 then
      return
    end

    if not failed then
      pcall(produceStandard, stamp, cluster, buckets)

      if _advancedMetrics then
        pcall(produceAdvanced, stamp, cluster, buckets)
      end
    end

    schedule()
  end

  retrieve('/pools/nodes', function(failure, data)
    if failure then
      failed = true
    else
      cluster = data
    end

    remain = remain - 1
    produce()
  end)

    for _, bucket in ipairs(_buckets) do

      retrieve(string.format('/pools/default/buckets/%s/nodes/%s/stats?zoom=minute', bucket, _serverTarget), function(failure, data)
        if failure then
          failed = true
        else
          buckets[bucket] = data
        end

        remain = remain - 1
        produce()
      end)

    end
  end

end]]
