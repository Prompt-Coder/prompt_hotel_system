fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'prompt_hotel_system'
description 'Hotel system: rentable MLO rooms for any property that registers itself'
author 'Prompt Studio'
version '1.0.0'
license 'LGPL-3.0-or-later'
repository 'https://github.com/Prompt-Coder/prompt_hotel_system'

ui_page 'html/elevator.html'

files {
    'html/elevator.html',
    'html/elevator.css',
    'html/elevator.js',
}

shared_scripts {
    '@ox_lib/init.lua',
    'shared/ns.lua',
    'config.lua',
    'locales.lua',
    'shared/util.lua',
    'shared/schema.lua',
    'shared/rooms.lua',
}

server_scripts {
    'bridges/framework.lua',
    'bridges/money.lua',
    'bridges/inventory.lua',
    'bridges/persistence.lua',
    'server/registry.lua',
    'server/doors.lua',
    'server/rentals.lua',
    'server/api.lua',
    'server/bar.lua',
    'server/admin.lua',
    'server/test.lua',
}

client_scripts {
    'bridges/notify.lua',
    'bridges/target.lua',
    'bridges/appearance.lua',
    'client/registry.lua',
    'client/blips.lua',
    'client/reception.lua',
    'client/rooms.lua',
    'client/streaming.lua',
    'client/elevator.lua',
    'client/bar.lua',
    'client/place.lua',
    'client/ptfxtest.lua',
}
