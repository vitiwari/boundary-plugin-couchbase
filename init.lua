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
local table = require('table')
local Plugin = framework.Plugin 
local WebRequestDataSource = framework.WebRequestDataSource
local notEmpty = framework.string.notEmpty
local auth = framework.util.auth
local clone = framework.table.clone
local percentage = framework.util.percentage
local isHttpSuccess = framework.util.isHttpSuccess
local PollerCollection = framework.PollerCollection
local DataSourcePoller = framework.DataSourcePoller
local ipack = framework.util.ipack

local params = framework.params
params.pollInterval = notEmpty(tonumber(params.pollInterval), 5000)
params.host = notEmpty(params.host, '127.0.0.1')
params.port = notEmpty(params.port, '8091')

-- 1. get /pools/nodes get the node & cluster based on the host parameter .
-- 2. get /pools/default/buckets for a list of available buckets for advanced metrics. 
-- 3. get /pools/default/buckets/%s/stats for each bucket for bucket level advanced metrics. .

local buckets = {}
local bucketCount = 0
local pending_requests = {}
local target
local options = {}
options.host = params.host
options.port = params.port
options.auth = auth(params.username, params.password)
options.path = '/pools/nodes'
options.source = notEmpty(params.source,params.host)
options.wait_for_end = true
options.meta = "clusterreq"



local function clusterNodeStatsExtractor (data, item)
	local result = {}
	local function metric(...)
      	ipack(result, ...)
	end
	
	local src = options.source
	metric('COUCHBASE_CLSTR_RAM_QUOTA_TOTAL', data.storageTotals.ram.quotaTotal,nil,src)
	metric('COUCHBASE_CLSTR_RAM_QUOTA_USED', data.storageTotals.ram.quotaUsed,nil,src)
    metric('COUCHBASE_CLSTR_HDD_QUOTA_TOTAL', data.storageTotals.hdd.quotaTotal,nil,src)
    metric('COUCHBASE_CLSTR_HDD_USED', data.storageTotals.hdd.used,nil,src)
  local count=0
  for i, node in ipairs(data.nodes) do
    count=count+1
    local ip, port = node.hostname:match'(.-):(.*)'
    local src1=src.."_"..ip;   
    metric('COUCHBASE_NODE_CPU_USAGE_RATE', percentage(node.systemStats.cpu_utilization_rate),nil,src1)
    metric('COUCHBASE_NODE_RAM_SYSTEM_TOTAL', node.systemStats.mem_total,nil,src1)
    metric('COUCHBASE_NODE_RAM_SYSTEM_FREE', node.systemStats.mem_free,nil,src1)
    metric('COUCHBASE_NODE_SWAP_TOTAL', node.systemStats.swap_used,nil,src1)
    metric('COUCHBASE_NODE_SWAP_USED', node.systemStats.swap_total,nil,src1)
    metric('COUCHBASE_NODE_OPERATIONS', node.interestingStats.ops,nil,src1)
    metric('COUCHBASE_NODE_DOCUMENTS_COUNT', node.interestingStats.curr_items,nil,src1)
    metric('COUCHBASE_NODE_DOCUMENTS_SIZE', node.interestingStats.couch_docs_data_size,nil,src1)
    metric('COUCHBASE_NODE_DOCUMENTS_SIZE_ON_DISK', node.interestingStats.couch_docs_actual_disk_size,nil,src1)
    metric('COUCHBASE_NODE_VIEWS_SIZE', node.interestingStats.couch_views_data_size,nil,src1)
    metric('COUCHBASE_NODE_VIEWS_SIZE_ON_DISK', node.interestingStats.couch_views_actual_disk_size,nil,src1)
  end
   metric('COUCHBASE_CLSTR_NODE_COUNT', count,nil,src)
   metric('COUCHBASE_CLSTR_BUCKET_COUNT',bucketCount,nil,src)
	return result
end

local stats_total_tmpl = {
  couch_docs_fragmentation = 0,
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
  replication_changes_left = 0
}

local function bucketStatsExtractor (data1, item , bucketName)
  local data = clone(stats_total_tmpl)
  for k, v in pairs(data) do
    local samples = data1.op.samples[k] or {} 
    data[k] = v + tonumber(samples[#samples] or 0)
  end
  
	local result = {}
	local metric = function (...) ipack(result, ...) end
	local src = options.source .. ".bucket."..bucketName
	metric('COUCHBASE_BUCKET_DOC_FRAGMENTATION', percentage(data.couch_docs_fragmentation),nil,src)
	metric('COUCHBASE_BUCKET_VIEWS_FRAGMENTATION', percentage(data.couch_views_fragmentation),nil,src)
  metric('COUCHBASE_BUCKET_VIEWS_OPERATIONS', data.couch_views_ops,nil,src)
  metric('COUCHBASE_BUCKET_DISK_COMMIT_TIME', data.avg_disk_commit_time,nil,src)
  metric('COUCHBASE_BUCKET_DISK_UPDATE_TIME', data.avg_disk_update_time,nil,src)
  metric('COUCHBASE_BUCKET_CAS_HITS', data.cas_hits,nil,src)
  metric('COUCHBASE_BUCKET_CAS_MISSES', data.cas_misses,nil,src)
  metric('COUCHBASE_BUCKET_DISK_FETCHES', data.ep_bg_fetched,nil,src)
  metric('COUCHBASE_BUCKET_EVICTIONS', data.evictions,nil,src)
  metric('COUCHBASE_BUCKET_MISSES', data.misses,nil,src)
  metric('COUCHBASE_BUCKET_XDCR_OPERATIONS', data.xdc_ops,nil,src)
  metric('COUCHBASE_BUCKET_REPL_CHANGES_LEFT', data.replication_changes_left,nil,src)
	return result
end



	local function createOptions(item)

		local options = {}
		options.host = item.host
		options.port = item.port
		options.wait_for_end = true
		options.auth=auth(item.username, item.password)
		options.source = item.source
		return options
	end
	local function createClusterStats(item)
		local options = createOptions(item)
		options.path = "/pools/nodes"
		options.meta = "clusterreq"
		return WebRequestDataSource:new(options)
	end	
	
	local function createBucketStats(item,bucket)
		local options = createOptions(item)
		options.path = '/pools/default/buckets/'..bucket..'/stats'
		options.meta = bucket
		return WebRequestDataSource:new(options)
	end	
	
	local function createPollers()
		local pollers = PollerCollection:new()

		local cs = createClusterStats(params)
		local clusterStatsPoller = DataSourcePoller:new(params.pollInterval, cs)
		pollers:add(clusterStatsPoller)
     	print(" buckets have length"..#buckets)
		for i, bucket in ipairs(buckets) do
      local bs = createBucketStats(params,bucket)
			local bucketStatsPoller = DataSourcePoller:new(params.pollInterval, bs)
			pollers:add(bucketStatsPoller)
      bucketCount=bucketCount+1
		end 
	  return pollers
	end
 

local function run()
  local opts = clone(options)
  opts.path = '/pools/default/buckets'
  local buckets_ds = WebRequestDataSource:new(opts)
 -- buckets_ds:propagate('error', plugin)
  buckets_ds:fetch(nil, function (data, extra) 
    if not isHttpSuccess(extra.status_code) then
      plugin:emitEvent('error', 'Http Error', params.host, params.host, ('Http status code %s'):format(extra.status_code))
      return
    end
    local parsed = json.parse(data)
    for _, bucket in ipairs(parsed) do
      table.insert(buckets, bucket.name)
    end
    local pollers = createPollers();
	local plugin = Plugin:new(params, pollers)
	
	function plugin:onParseValues(data, extra)
				if not extra.info then
				  return
				end
				local parsed = json.parse(data)
				local result= {}
				if extra.info == "clusterreq" then
				  result= clusterNodeStatsExtractor(parsed , options)
				else
				  result= bucketStatsExtractor( parsed , options,extra.info)
				end
		return result
	end		
	plugin:run()
  end)
end

run()
