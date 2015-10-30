-- vim:ts=4:sw=4:noexpandtab
local dpdk              = require "dpdk"
local memory    = require "memory"
local device    = require "device"
local ts                = require "timestamping"
local stats             = require "stats"
local hist              = require "histogram"

local PKT_SIZE  = 64

function master(...)
        local txPort, rxPort, rate= tonumberall(...)
        if not txPort or not rxPort then
                return print("usage: txPort rxPort [rate]")
        end
        rate = rate or 10000
        -- hardware rate control fails with small packets at these rates
        local numQueues = rate > 6000 and rate < 10000 and 3 or 1
        local txDev = device.config(txPort, 2, 4)
        local rxDev = device.config(rxPort, 2, 1) -- ignored if txDev == rxDev
        local queues = {}
        for i = 1, numQueues do
                local queue = txDev:getTxQueue(i)
                queues[#queues + 1] = queue
                if rate < 10000 then -- only set rate if necessary to work with devices that don't support hw rc
                        queue:setRate(rate / numQueues)
                end
        end
        dpdk.launchLua("loadSlave", queues, txDev, rxDev)
        dpdk.launchLua("timerSlave", txDev:getTxQueue(0), rxDev:getRxQueue(1))
        dpdk.waitForSlaves()
end

function loadSlave(queues, txDev, rxDev)
        local mem = memory.createMemPool(function(buf)
                buf:getEthernetPacket():fill{
                        ethSrc = txDev,
                        --ethDst = ETH_DST,
                        ethDst = "90:e2:ba:4a:e8:08",
                        ethType = 0x1234
                }
        end)
        local bufs = mem:bufArray()
        local txCtr = stats:newDevTxCounter(txDev, "plain")
        local rxCtr = stats:newDevRxCounter(rxDev, "plain")
        while dpdk.running() do
                for i, queue in ipairs(queues) do
                        bufs:alloc(PKT_SIZE)
                        queue:send(bufs)
                end
                txCtr:update()
                rxCtr:update()
        end
        txCtr:finalize()
        rxCtr:finalize()

end

function timerSlave(txQueue, rxQueue)
        local timestamper = ts:newTimestamper(txQueue, rxQueue)
        local hist = hist:new()
        local count = 0
        --local loops = 100
        local loops = 1000
        dpdk.sleepMillis(1000) -- ensure that the load task is running
        while dpdk.running() do
                hist:update(timestamper:measureLatency())
                count = count + 1
                if count % 10000 == 0 then
                        hist:print()
                        loops = loops - 1
                        if loops == 0 then
                                hist:print()
                                hist:save("histogram.csv")
                                dpdk.stop()
                                break
                        end
                end
        end
        hist:print()
        hist:save("histogram.csv")
end

       
