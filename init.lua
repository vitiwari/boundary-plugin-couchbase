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
local PollerCollection = framework.PollerCollection
local DataSourcePoller = framework.DataSourcePoller
local notEmpty = framework.string.notEmpty
local auth = framework.util.auth
local hasAny = framework.table.hasAny
local clone = framework.table.clone
local table = require('table')
local find = framework.table.find
local percentage = framework.util.percentage
local isHttpSuccess = framework.util.isHttpSuccess

local params = framework.params
params.pollInterval = notEmpty(tonumber(params.pollInterval), 1000)
params.host = notEmpty(params.host, 'localhost')
params.port = notEmpty(params.port, '8091')
params.advanced_metrics = params.advanced_metrics or false

-- 1. get /pools/nodes get the node based on the host parameter.
-- 2. get /pools/default/buckets for a list of available buckets for advanced metrics. This can be done with a CachedWebRequestDataSource
-- 3. get /pools/default/buckets/%s/nodes/%s/stats?zoom=minute for each bucket for advanced metrics. This can be a list of child request returned by the chain function.

local buckets = {}
local pending_requests = {}
local target
local plugin

local function getNode(nodes, hostname)
  return find(function (v) return v.hostname == hostname end, nodes) 
end

local function standardMetrics(cluster)
  local result = {}
  result['COUCHBASE_RAM_QUOTA_TOTAL'] = cluster.storageTotals.ram.quotaTotalPerNode or 0
  result['COUCHBASE_RAM_QUOTA_USED'] = cluster.storageTotals.ram.quotaUsedPerNode or 0

  local node = getNode(cluster.nodes, target)
  if node then
    result['COUCHBASE_CPU_USAGE_RATE'] = percentage(node.systemStats.cpu_utilization_rate or 0)
    result['COUCHBASE_RAM_SYSTEM_TOTAL'] = node.systemStats.mem_total or 0
    result['COUCHBASE_RAM_SYSTEM_FREE'] = node.systemStats.mem_free or 0
    result['COUCHBASE_SWAP_TOTAL'] = node.systemStats.swap_total or 0
    result['COUCHBASE_SWAP_USED'] = node.systemStats.swap_used or 0
    result['COUCHBASE_OPERATIONS'] = node.interestingStats.ops or 0
    result['COUCHBASE_DOCUMENTS_COUNT'] = node.interestingStats.curr_items or 0
    result['COUCHBASE_DOCUMENTS_SIZE'] = node.interestingStats.couch_docs_data_size or 0
    result['COUCHBASE_DOCUMENTS_SIZE_ON_DISK'] = node.interestingStats.couch_docs_actual_disk_size or 0
    result['COUCHBASE_VIEWS_SIZE'] = node.interestingStats.couch_views_data_size or 0
    result['COUCHBASE_VIEWS_SIZE_ON_DISK'] = node.interestingStats.couch_views_actual_disk_size or 0
  end
  
  return result
end

local options = {}
options.host = params.host
options.port = params.port
options.auth = auth(params.username, params.password)
options.path = '/pools/nodes'
options.wait_for_end = true
local ds = WebRequestDataSource:new(options)
ds:chain(function (context, callback, data)
  local cluster = json.parse(data)
  
  local metrics = standardMetrics(cluster)
  plugin:report(metrics)

  if params.advanced_metrics then
    local data_sources = {}
    for i, bucket in ipairs(buckets) do
      local node = target 
      local opts = clone(options)
      opts.meta = bucket
      opts.path = ('/pools/default/buckets/%s/nodes/%s/stats?zoom=minute'):format(bucket, node)
      local child_ds = WebRequestDataSource:new(opts)
      child_ds:propagate('error', context)
      table.insert(data_sources, child_ds)
      pending_requests[bucket] = true
    end
    return data_sources
  end
end)

-- For the standard metrics we look for the node that has the same IP and port as the specified parameters.
-- For the advanced metrics we get a list of buckets and then agregate bucket metrics
local stats_total_tmpl = {
  couch_views_fragmentation = 0,
  couch_views_fragmentation = 0,
  couch_views_ops = 0,
  avg_disk_commit_time = 0,
  avg_disk_update_time = 0,
  cas_hits = 0,
  cas_misses = 0,
  ep_bg_fetched = 0,
  evictions = 0,
  misses = 0,
  xdc_ops = 0,
  replication_changes_left = 0,
  major_faults = 0,
  minor_faults = 0,
  page_faults = 0
}

local stats_total = clone(stats_total_tmpl)

plugin = Plugin:new(params, ds)
function plugin:onParseValues(data, extra)
  if not extra.info then
    return
  end

  local parsed = json.parse(data)
  for k, v in pairs(stats_total) do
    local samples = parsed.op.samples[k] or {} 
    stats_total[k] = v + tonumber(samples[#samples]) or 0
  end

  pending_requests[extra.info] = nil
  if not hasAny(pending_requests) then
    local result = {}
    result['COUCHBASE_DOCUMENTS_FRAGMENTATION'] = percentage(stats_total.couch_views_fragmentation)
    result['COUCHBASE_VIEWS_FRAGMENTATION'] = percentage(stats_total.couch_views_fragmentation)
    result['COUCHBASE_VIEWS_OPERATIONS'] = stats_total.couch_views_ops
    result['COUCHBASE_DISK_COMMIT_TIME'] = stats_total.avg_disk_commit_time
    result['COUCHBASE_DISK_UPDATE_TIME'] = stats_total.avg_disk_update_time
    result['COUCHBASE_CAS_HITS'] = stats_total.cas_hits
    result['COUCHBASE_CAS_MISSES'] = stats_total.cas_misses
    result['COUCHBASE_DISK_FETCHES'] = stats_total.ep_bg_fetched
    result['COUCHBASE_EVICTIONS'] = stats_total.evictions
    result['COUCHBASE_MISSES'] = stats_total.misses
    result['COUCHBASE_XDCR_OPERATIONS'] = stats_total.xdc_ops
    result['COUCHBASE_REPLICATION_CHANGES_LEFT'] = stats_total.replication_changes_left
    result['COUCHBASE_MAJOR_FAULTS'] = stats_total.major_faults
    result['COUCHBASE_MINOR_FAULTS'] = stats_total.minor_faults
    result['COUCHBASE_PAGE_FAULTS'] = stats_total.page_faults
  
    stats_total = clone(stats_total_tmpl)
    return result
  end
end

local function resolveHost(host)
  dns.resolve(host, function (failure, addresses)
    if failure then
      plugin:emitEvent('critical', ('%s Unresolved'):format(host), host, host, ('Could not resolve the %s'):format(host))
      return
    end

    target = addresses[1] .. ':' .. params.port 
    plugin:run()
  end)
end

local function run()
  local opts = clone(options)
  opts.path = '/pools/default/buckets'
  local buckets_ds = WebRequestDataSource:new(opts)
  buckets_ds:propagate('error', plugin)
  buckets_ds:fetch(nil, function (data, extra) 
    if not isHttpSuccess(extra.status_code) then
      plugin:emitEvent('error', 'Http Error', params.host, params.host, ('Http status code %s'):format(extra.status_code))
      return
    end
    local parsed = json.parse(data)
    for _, bucket in ipairs(parsed) do
      table.insert(buckets, bucket.name)
    end
    resolveHost(params.host)
  end)
end

run()
