Locale = {
    rented = 'Room rented — floor %d, room %d. The elevator is by the lobby.',
    extended = 'Rent extended.',
    rent_ended = 'Checkout complete.',
    evicted = 'Your hotel rent expired — the room has been released.',
    no_room_free = 'No rooms of that type are free.',
    no_money = 'Not enough money.',
    already_renting = 'You already rent a room.',
    not_renting = 'You are not renting a room.',
    door_locked = 'Locked.',
    door_unlocked = 'Unlocked.',
    no_access = 'No access.',
    too_far_desk = 'Step up to the front desk first.',
    too_far_bar = 'Stand at the bar first.',
    slow_down = 'One moment — try again in a second.',
    max_days = 'That would take you past the maximum rental length — let some time run down first.',
    bad_days = 'That is not a valid number of days.',
    bar_closed = 'The bar is not serving.',
    not_ready = 'The front desk is not open yet — try again in a moment.',
    guest_added = 'Guest key given.',
    guest_removed = 'Guest key revoked.',
    guest_limit = 'Guest limit reached.',
    stash = 'Room storage',
    room_blip = 'Hotel Room',
    use_elevator = 'Use elevator',
    talk_receptionist = 'Talk to receptionist',
    lock_toggle = 'Lock / unlock door',
    open_stash = 'Open storage',
    use_wardrobe = 'Wardrobe',
    use_shower = 'Take a shower',
    use_bath = 'Take a bath',
    order_drink = 'Order a drink',
    bar_busy = 'The bartender is busy — one moment.',
    invalid_drink = 'We do not serve that.',
}

function L(key, ...)
    local s = Locale[key] or key
    if select('#', ...) > 0 then return s:format(...) end
    return s
end
