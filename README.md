# Boundary Couchbase Plugin

Tracks the fork rate on your server by polling the Couchbase REST API at "http://localhost:8091/" (configurable setting).

### Prerequisites

#### Supported OS

|     OS    | Linux | Windows | SmartOS | OS X |
|:----------|:-----:|:-------:|:-------:|:----:|
| Supported |   v   |    v    |    v    |  v   |

- Written in pure Lua/Luvit (embedded in `boundary-meter`) therefore **no dependencies** are required.
- Metrics are collected via HTTP requests, therefore **all OSes** should work (tested on **Debian-based Linux** distributions).

#### Requires Boundary Meter Versions V4.0 or later

- To install new meter go to Settings->Installation or [see instructons](https://help.boundary.com/hc/en-us/sections/200634331-Installation).
- To upgrade the meter to the latest version - [see instructons](https://help.boundary.com/hc/en-us/articles/201573102-Upgrading-the-Boundary-Meter). 

### Plugin Setup

#### Couchbase Server

- A working server
- Configured to run on the same machine (reachable at `127.0.0.1:8091`)

### Plugin Configuration Fields

For advanced metrics please set a longer polling interval to minimize load on the Couchbase instance (e.g. 5000ms or more).

|Setting Name       | Description                                                                              |
|:------------------|:----------------------------------------------------------------------------------------|
| Host              | Couchbase service host for the node (default: 'localhost').                          |
| Port              | The Couchbase service port for the node (default: 8091).                                 |
| Username          | The administrative username to access the Couchbase server |
| Password          | The administrative password to access the Couchbase server (default: '').                |
| Poll Interval     | How often (in milliseconds) to poll the Couchbase node for metrics.      |
| Advanced Metrics  | Produce more detailed metrics (more expensive to compile, default: false).               |

### Metrics Collected

#### Standard Metrics

|Metric Name                         |Description                                                                                        |
|:-----------------------------------|:--------------------------------------------------------------------------------------------------|
|COUCHBASE_RAM_QUOTA_TOTAL           |Total quota of memory allocated by the Couchbase cluster for this node.                            |
|COUCHBASE_RAM_QUOTA_USED            |Amount of memry used on this node by Couchbase from the allocated quota.                           |
|COUCHBASE_CPU_USAGE_RATE            |CPU utilization percent.                                                                           |
|COUCHBASE_RAM_SYSTEM_TOTAL          |Total amount of memory on this node as reported by Couchbase.                                      |
|COUCHBASE_RAM_SYSTEM_FREE           |Amount of memory used on this node as reported by Couchbase.                                       |
|COUCHBASE_SWAP_TOTAL                |Total swap space on this node as reported by Couchbase.                                            |
|COUCHBASE_SWAP_USED                 |Userd swap space on this node as reported by Couchbase.                                            |
|COUCHBASE_OPERATIONS                |Number of currently on-going operations on this node.                                              |
|COUCHBASE_DOCUMENTS_COUNT           |Number of documents stored on this node.                                                           |
|COUCHBASE_DOCUMENTS_SIZE            |Size of the data in the documents stored on this node.                                             |
|COUCHBASE_DOCUMENTS_SIZE_ON_DISK    |Size on disk of the documents stored on this node.                                                 |
|COUCHBASE_VIEWS_SIZE                |Size of the data in the indexed views on this node.                                                |
|COUCHBASE_VIEWS_SIZE_ON_DISK        |Size on disk of the indexed views on this node.                                                    |

#### Advanced Metrics (more expensive retrieval)

|Metric Name                         |Description                                                                                        |
|:-----------------------------------|:--------------------------------------------------------------------------------------------------|
|COUCHBASE_DOCUMENTS_FRAGMENTATION   |Rate of fragmentation of document data.                                                            |
|COUCHBASE_VIEWS_FRAGMENTATION       |Rate of fragmentation of views data (i.e. indexes).                                                |
|COUCHBASE_VIEWS_OPERATIONS          |Number of currently on-going views-related operations on this node (e.g. queries).                 |
|COUCHBASE_DISK_COMMIT_TIME          |Average time for disk commit operations on this node.                                              |
|COUCHBASE_DISK_UPDATE_TIME          |Average time for disk update operations on this node.                                              |
|COUCHBASE_CAS_HITS                  |Number of successful CAS comparisons.                                                              |
|COUCHBASE_CAS_MISSES                |Number of unsuccessful CAS comparisons.                                                            |
|COUCHBASE_DISK_FETCHES              |Number of times Couchbase went to disk to get data (non-resident data) per second.                 |
|COUCHBASE_EVICTIONS                 |Number of times COuchbase evicted data from the resident memory to free-up space.                  |
|COUCHBASE_MISSES                    |Number of operations on missing documents.                                                         |
|COUCHBASE_XDCR_OPERATIONS           |Cross-datacenter replication operations on this node.                                              |
|COUCHBASE_REPLICATION_CHANGES_LEFT  |Number of replication operations queued and yet to be performed.                                   |
|COUCHBASE_MAJOR_FAULTS              |Number of major faults on this node.                                                               |
|COUCHBASE_MINOR_FAULTS              |Number of minor faults on this node.                                                               |
|COUCHBASE_PAGE_FAULTS               |Number of memory page faults on this node.                                                         |
|COUCHBASE_ACTIVE_CONNECTIONS        |Number of currently active connections established with this node.                                 |

### Dashboards

### References

[Couchbase REST API Reference](http://docs.couchbase.com/admin/admin/rest-intro.html)
