from __future__ import print_function
import topsprocs
import flotgraph
import time
import tabledata
import hosts
import tplE
import reportdata
import cherrypy


class MonitorFrontend(object):

        def __init__(self, hostId):
            self.hostId = hostId


        def default(self, hostId = None):
            hostId, hostUiName = hosts.ensureHostIdAndUIShortname(max(hostId, self.hostId))
            days = cherrypy.request.cookie['days'].value if 'days' in cherrypy.request.cookie else '8'
            sprocs_to_show = int(cherrypy.request.cookie['sprocs_to_show'].value) if 'sprocs_to_show' in cherrypy.request.cookie else 10
            graph_load = None
            graph_wal = None
            graph_size = None
            graph_dbstats = None
            top_sprocs = None

            if tplE._settings['show_load']:
                graph_load = flotgraph.Graph("graph_load","left",30)
                graph_load.addSeries('CPU Load 15min avg','acpu_15min_avg','#FF0000')
                cpuload = topsprocs.getCpuLoad(hostId, days)
                for p in cpuload['load_15min_avg']:
                    graph_load.addPoint('acpu_15min_avg', int(time.mktime(p[0].timetuple()) * 1000) , p[1])

                load = topsprocs.getLoad(hostId, days)
                graph_load.addSeries('Sproc Load 15 min', 'load_15min')
                for p in load['load_15min']:
                    graph_load.addPoint('load_15min', int(time.mktime(p[0].timetuple()) * 1000) , p[1])
                graph_load = graph_load.render()

            if tplE._settings['show_wal']:
                graph_wal = flotgraph.Graph("graph_wal", "left", 30)
                graph_wal.addSeries('WAL vol. 15 min (in MB)', 'wal_15min')
                walvolumes = topsprocs.getWalVolumes(hostId, days)
                for p in walvolumes['wal_15min_growth']:
                    graph_wal.addPoint('wal_15min', int(time.mktime(p[0].timetuple()) * 1000) , p[1])

                if hosts.isHostFeatureEnabled(hostId, 'blockingStatsGatherInterval'):
                    blocked_processes = topsprocs.getBlockedProcessesCounts(hostId, days)
                    graph_wal.addSeries('#Blocked processes (> 5s)', 'blocked_processes', '#FF0000', None, 2)
                    for p in blocked_processes:
                        if len(walvolumes['wal_15min_growth']) > 0 \
                                and p[0].timetuple() >= walvolumes['wal_15min_growth'][0][0].timetuple(): # aligning timeline with WAL data
                            graph_wal.addPoint('blocked_processes', int(time.mktime(p[0].timetuple()) * 1000), p[1])
                graph_wal = graph_wal.render()

            if tplE._settings['show_db_size']:
                graph_size = flotgraph.SizeGraph("graph_size")
                sizes = tabledata.getDatabaseSizes(hostId, days)
                if hostId in sizes:
                    tabledata.fillGraph(graph_size,sizes[hostId])
                graph_size = graph_size.render()

            if tplE._settings['show_db_stats']:
                dbstats = reportdata.getDatabaseStatistics(hostId, days)
                if len(dbstats) > 0:
                    graph_dbstats = flotgraph.SizeGraph("graph_dbstats")
                    graph_dbstats.addSeries('Temp bytes written', 'temp_files_bytes')
                    graph_dbstats.addSeries('#Backends / 10', 'numbackends', '#C0C0C0', None, 2)
                    graph_dbstats.addSeries('#Deadlocks', 'deadlocks', '#FF0000', None, 2)
                    graph_dbstats.addSeries('#Rollbacks [incl. exceptions]', 'rollbacks', '#FFFF00', None, 2)
                    for d in dbstats:
                        timestamp = int(time.mktime(d['timestamp'].timetuple()) * 1000)
                        graph_dbstats.addPoint('temp_files_bytes', timestamp, d['temp_files_bytes'])
                        graph_dbstats.addPoint('deadlocks', timestamp, d['deadlocks'])
                        graph_dbstats.addPoint('numbackends', timestamp, d['numbackends'] / 10.0)
                        graph_dbstats.addPoint('rollbacks', timestamp, d['rollbacks'])
                    graph_dbstats = graph_dbstats.render()

            if tplE._settings['show_top_sprocs']:
                top_sprocs = {}
                top_sprocs['hours1avg'] = self.renderTop10LastHours(topsprocs.avgRuntimeOrder,1, hostId, sprocs_to_show)
                top_sprocs['hours3avg'] = self.renderTop10LastHours(topsprocs.avgRuntimeOrder,3, hostId, sprocs_to_show)

                top_sprocs['hours1total'] = self.renderTop10LastHours(topsprocs.totalRuntimeOrder,1, hostId,sprocs_to_show)
                top_sprocs['hours3total'] = self.renderTop10LastHours(topsprocs.totalRuntimeOrder,3, hostId,sprocs_to_show)

                top_sprocs['hours1calls'] = self.renderTop10LastHours(topsprocs.totalCallsOrder,1, hostId,sprocs_to_show)
                top_sprocs['hours3calls'] = self.renderTop10LastHours(topsprocs.totalCallsOrder,3, hostId,sprocs_to_show)

            tmpl = tplE.env.get_template('index.html')
            return tmpl.render(hostid=hostId,
                               hostname=hosts.getHostnameByHostId(hostId),
                               hostuiname=hostUiName,
                               graph_load=graph_load,
                               graph_wal=graph_wal,
                               graph_size=graph_size,
                               graph_dbstats=graph_dbstats,
                               top_sprocs=top_sprocs,
                               limit=sprocs_to_show,
                               features=hosts.getActiveFeatures(hostId),
                               target='World')


        def raw(self, host, limit=10):  # raw should contain all data to build up the page dynamically for example
            hostId, host_ui_name = hosts.ensureHostIdAndUIShortname(host)
            cpuload = topsprocs.getCpuLoad(hostId)
            load = topsprocs.getLoad(hostId)
            walvolumes = topsprocs.getWalVolumes(hostId)
            blocked_processes = topsprocs.getBlockedProcessesCounts(hostId)
            sizes = tabledata.getDatabaseSizes(hostId)
            dbstats = reportdata.getDatabaseStatistics(hostId)

            result = {'load': load, 'cpuload': cpuload, 'walvolumes': walvolumes, 'blocked_processes': blocked_processes, 'sizes': sizes, 'dbstats': dbstats}
            return result


        def index(self, limit=10):
            return self.default(self.hostId, limit)


        def renderTop10AllTime(self, order):
            table = tplE.env.get_template('table.html')
            return table.render(list=topsprocs.getTop10AllTimes(order))


        def renderTop10LastHours(self, order, hours, hostId, limit):
            table = tplE.env.get_template('table.html')
            return table.render(hostid = hostId, hostuiname=hosts.hostIdToUiShortname(hostId), list=topsprocs.getTop10LastXHours(order, hours, hostId,limit))

        index.exposed = False
        default.exposed = True
