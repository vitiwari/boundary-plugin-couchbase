--
-- [boundary.com] Couchbase Lua Plugin
-- [author] Valeriu Paloş <me@vpalos.com>
--

--
-- Imports.
--
local dns   = require('dns')
local fs    = require('fs')
local io    = require('io')
local json  = require('json')
local http  = require('http')
local os    = require('os')
local timer = require('timer')
local tools = require('tools')
local url   = require('url')

--
-- Initialize.
--
local _buckets          = {}
local _parameters       = json.parse(fs.readFileSync('param.json')) or {}

local _serverHost       = _parameters.serverHost or 'localhost'
local _serverPort       = _parameters.serverPort or 8091
local _serverAddress
local _serverTarget

local _serverUsername   = _parameters.serverUsername or 'admin'
local _serverPassword   = _parameters.serverPassword or ''
local _pollRetryCount   = tools.fence(tonumber(_parameters.pollRetryCount) or    5,   0, 1000)
local _pollRetryDelay   = tools.fence(tonumber(_parameters.pollRetryDelay) or 3000,   0, 1000 * 60 * 60)
local _pollInterval     = tools.fence(tonumber(_parameters.pollInterval)   or 5000, 100, 1000 * 60 * 60 * 24)
local _advancedMetrics  = _parameters.advancedMetrics == true

--
-- Metrics source.
--
local _source =
  (type(_parameters.source) == 'string' and _parameters.source:gsub('%s+', '') ~= '' and _parameters.source) or
   io.popen("uname -n"):read('*line')

--
-- Get a JSON data set from the server at the given URL (includes query string)
--
function retrieve(location, callback)
  local _pollRetryRemaining = _pollRetryCount

  local options = url.parse('http://' .. _serverTarget .. location)
  options.headers = {
    ['Accept'] = 'application/json',
    ['Authorization'] = 'Basic ' .. tools.base64(_serverUsername .. ':' .. _serverPassword)
  }

  function handler(response)
    if (response.status_code ~= 200) then
      return retry("Unexpected status code " .. response.status_code .. ", should be 200!")
    end

    local data = {}
    response:on('data', function(chunk)
      table.insert(data, chunk)
    end)
    response:on('end', function()
      local success, json = pcall(json.parse, table.concat(data))

      if success then
        callback(nil, json)
      else
        callback("Unable to parse incoming data as a valid JSON value!")
      end

      response:destroy()
    end)

    response:once('error', retry)
  end

  function retry(result)
    if _pollRetryRemaining == 0 then
      return callback(result)
    elseif _pollRetryRemaining > 0 then
      _pollRetryRemaining = _pollRetryRemaining - 1
    end
    timer.setTimeout(_pollRetryDelay, perform)
  end

  function perform()
    local request = http.request(options, handler)
    request:once('error', retry)
    request:done()
  end

  perform()
end

--
-- Schedule poll.
--
function schedule()
  timer.setTimeout(_pollInterval, poll)
end

--
-- Print a metric.
--
function metric(stamp, id, value)
  print(string.format('%s %s %s %d', id, value, _source, stamp))
end

--
-- Compile and print standard metrics from given data.
--
function produceStandard(stamp, cluster, buckets)
  metric(stamp, 'COUCHBASE_RAM_QUOTA_TOTAL',          cluster.storageTotals.ram.quotaTotalPerNode or 0)
  metric(stamp, 'COUCHBASE_RAM_QUOTA_USED',           cluster.storageTotals.ram.quotaUsedPerNode or 0)

  local selectedNode
  for _, node in ipairs(cluster.nodes) do
    if node.hostname == _serverTarget then
      selectedNode = node
      break
    end
  end

  if selectedNode then
    metric(stamp, 'COUCHBASE_CPU_USAGE_RATE',         selectedNode.systemStats.cpu_utilization_rate or 0)
    metric(stamp, 'COUCHBASE_RAM_SYSTEM_TOTAL',       selectedNode.systemStats.mem_total or 0)
    metric(stamp, 'COUCHBASE_RAM_SYSTEM_FREE',        selectedNode.systemStats.mem_free or 0)
    metric(stamp, 'COUCHBASE_SWAP_TOTAL',             selectedNode.systemStats.swap_total or 0)
    metric(stamp, 'COUCHBASE_SWAP_USED',              selectedNode.systemStats.swap_used or 0)
    metric(stamp, 'COUCHBASE_OPERATIONS',             selectedNode.interestingStats.ops or 0)
    metric(stamp, 'COUCHBASE_DOCUMENTS_COUNT',        selectedNode.interestingStats.curr_items or 0)
    metric(stamp, 'COUCHBASE_DOCUMENTS_SIZE',         selectedNode.interestingStats.couch_docs_data_size or 0)
    metric(stamp, 'COUCHBASE_DOCUMENTS_SIZE_ON_DISK', selectedNode.interestingStats.couch_docs_actual_disk_size or 0)
    metric(stamp, 'COUCHBASE_VIEWS_SIZE',             selectedNode.interestingStats.couch_views_data_size or 0)
    metric(stamp, 'COUCHBASE_VIEWS_SIZE_ON_DISK',     selectedNode.interestingStats.couch_views_actual_disk_size or 0)
  end
end

--
-- Compile and print advanced metrics from given data.
--
function produceAdvanced(stamp, cluster, buckets)
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
function poll()

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

  if _advancedMetrics then
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

end

--
-- Query Couchbase for buckets.
--
function scan()
  retrieve('/pools/default/buckets', function(failure, buckets)
    if failure then
      error("Failed to read Couchbase infrastructure: " .. tostring(failure) .. "!")
    end

    for _, bucket in ipairs(buckets) do
      table.insert(_buckets, bucket.name)
    end

    -- Trigger repetitive collection.
    poll()
  end)
end

--
-- Resolve server DNS into IP form and trigger cluster scan (which triggers polling).
--
dns.resolve(_serverHost, function(failure, addresses)
  if failure then
    error(string.format("Unable to resolve server hostname '%s': %s!", _serverHost, failure))
  end

  -- Compile target.
  _serverAddress = addresses[1]
  _serverTarget = _serverAddress .. ':' .. _serverPort

  -- Trigger cluster scan.
  scan()
end)
