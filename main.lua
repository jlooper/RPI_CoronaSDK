
display.setStatusBar( display.HiddenStatusBar )

local MQTT = require("mqtt.mqtt_library")
MQTT.Utility.set_debug(true)


-----------------------------------------------
-- Initialize static UI elements
-----------------------------------------------
local background = display.newRect(0,0,display.contentWidth, display.contentHeight)
    background:setFillColor(.29,.51,.80)
    background.x = display.contentWidth / 2
    background.y = display.contentHeight / 2


function callback(topic,payload)
  print("topic and payload",topic,payload)
end


mqtt_client = MQTT.client.create("iot.eclipse.org", 1883, callback)
mqtt_client:connect(system.getInfo( "deviceID" ))
mqtt_client.KEEP_ALIVE_TIME = 120
mqtt_client:subscribe({ "/jen" })


local function networkListener( event )
        if ( event.isError ) then
                print( "Network error!")
        else
                print ( event.response )
        end
end

local function onTouch( event )
    if event.phase == "ended" then
        print(event.target.id)
        if event.target.id == "red" then
          mqtt_client:publish("/jen", "red")  
        else
          mqtt_client:publish("/jen", "green")
        end
        return true
    end
end

local redCircle = display.newCircle( 100, 100, 30 )
redCircle.id = "red"
redCircle:setFillColor(1,0,0)
redCircle.x,redCircle.y = display.contentWidth/2, display.contentHeight/3
redCircle:addEventListener("touch",onTouch)

local greenCircle = display.newCircle( 100, 100, 30 )
greenCircle.id = "green"
greenCircle:setFillColor(0,1,0)
greenCircle.x,greenCircle.y = display.contentWidth/2, display.contentHeight/2
greenCircle:addEventListener("touch",onTouch)




timer.performWithDelay(500, function(event) mqtt_client:handler() end, 0)



