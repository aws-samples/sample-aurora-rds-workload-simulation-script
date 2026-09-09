---- Script places a new order using 
    --- a randomly generated address, 
    --- and using a fixed number of items (by default 1) per order.

if sysbench.cmdline.command == nil then
   error("Command is required. Supported commands: run")
end

sysbench.cmdline.options = {
    inventory_scale = {"Number of items in the data set", 10000000},
    user_scale = {"Number of users in the data set", 10000},
    items_per_order = {"Number of items per order", 1},
    skip_trx = {"Don't start explicit transactions and execute all queries in the AUTOCOMMIT mode", false}
}

-- Statements below use prepared statements with bound parameters (rather
-- than string interpolation) so generated values -- including the
-- delivery address fields -- can never be interpreted as SQL.
-- No RETURNING clause here: this statement is executed as a prepared
-- statement, and sysbench's PgSQL driver requests prepared-statement
-- results in binary wire format. fetch_row() would hand back raw binary
-- bytes for order_id (not decimal text), which tonumber() cannot safely
-- interpret. The new order_id is instead fetched via a separate
-- unprepared query in create_new_order(), which always returns text.
local insert_order_stmt = "INSERT INTO orders(userid, delivery_name, delivery_street_address, delivery_appartment_no, delivery_city, delivery_country, delivery_pincode, delivery_contact, order_dttm, order_status, order_status_dttm) " ..
    "VALUES (?, ?, ?, ?, ?, ?, ?, ?, current_timestamp, 'PLACED', current_timestamp)"

local inventory_update_stmt = "UPDATE item_inventory SET item_count=item_count - ? WHERE inventory_id=?"

local insert_order_items_stmt = "INSERT INTO order_items (order_id, item_id, item_count, userid, order_dttm) VALUES (?, ?, ?, ?, current_timestamp)"

local order_stmt, inventory_stmt, order_items_stmt
local ord_userid, ord_delivery_name, ord_delivery_street_address, ord_delivery_appartment_no, ord_delivery_city, ord_delivery_country, ord_delivery_pincode, ord_delivery_contact
local inv_item_count, inv_inventory_id
local oi_order_id, oi_item_id, oi_item_count, oi_userid

function create_random_string(charSet, minlenght, length)
       -- math.randomseed(os.time())
        randomString = ''
        randomTuple = {}
        for c in charSet:gmatch"." do
           table.insert(randomTuple, c)
        end

        len =sysbench.rand.pareto(minlenght, length)
        for i = 1, len do
           randomString = randomString .. randomTuple[sysbench.rand.uniform(1, #randomTuple)]
        end

        return randomString
end

function generate_street_address()
        local num = sysbench.rand.uniform(1,500)
        local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
        local street_name = create_random_string(chars, 70,100)
        return num .. ' ' .. street_name
end

function generate_contact_name()
        local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        local first_name = create_random_string(chars, 6, 20)
        local last_name = create_random_string(chars,6,20)
        return first_name .. ' ' .. last_name
end

function generate_city()
        local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        local city = create_random_string(chars, 8, 30)
        return city
end

function generate_country()
        local country_list = {"India","Singapore","USA","England","Scotland", "Malaysia","Australia","New Zealand","Indonesia","Germany","France","Belgium","Fiji"}
        local list_selector = sysbench.rand.uniform(1, 13)
        return country_list[list_selector]
end

function generate_contact()
        local first_digit = sysbench.rand.uniform(3, 9)
        local nums = '1234567890'
        return first_digit .. create_random_string(nums, 3, 6)
end

function generate_new_address()
        local contact_name = generate_contact_name()
        local street_address = generate_street_address()
        local appartment_no = sysbench.rand.uniform(1, 20) .. '-' .. sysbench.rand.uniform(1,30)
        local city = generate_city()
        local pincode = sysbench.rand.uniform(30000, 88888)
        local city = generate_city()
        local country = generate_country()
        local contact = generate_contact()

        return {contact_name, street_address, appartment_no, city, country, pincode,  contact}
end

function prepare_statements()
        order_stmt = con:prepare(insert_order_stmt)
        ord_userid = order_stmt:bind_create(sysbench.sql.type.BIGINT)
        ord_delivery_name = order_stmt:bind_create(sysbench.sql.type.VARCHAR, 200)
        ord_delivery_street_address = order_stmt:bind_create(sysbench.sql.type.VARCHAR, 200)
        ord_delivery_appartment_no = order_stmt:bind_create(sysbench.sql.type.VARCHAR, 50)
        ord_delivery_city = order_stmt:bind_create(sysbench.sql.type.VARCHAR, 100)
        ord_delivery_country = order_stmt:bind_create(sysbench.sql.type.VARCHAR, 100)
        ord_delivery_pincode = order_stmt:bind_create(sysbench.sql.type.VARCHAR, 10)
        ord_delivery_contact = order_stmt:bind_create(sysbench.sql.type.BIGINT)
        order_stmt:bind_param(ord_userid, ord_delivery_name, ord_delivery_street_address, ord_delivery_appartment_no,
                ord_delivery_city, ord_delivery_country, ord_delivery_pincode, ord_delivery_contact)

        inventory_stmt = con:prepare(inventory_update_stmt)
        inv_item_count = inventory_stmt:bind_create(sysbench.sql.type.BIGINT)
        inv_inventory_id = inventory_stmt:bind_create(sysbench.sql.type.BIGINT)
        inventory_stmt:bind_param(inv_item_count, inv_inventory_id)

        order_items_stmt = con:prepare(insert_order_items_stmt)
        oi_order_id = order_items_stmt:bind_create(sysbench.sql.type.BIGINT)
        oi_item_id = order_items_stmt:bind_create(sysbench.sql.type.BIGINT)
        oi_item_count = order_items_stmt:bind_create(sysbench.sql.type.BIGINT)
        oi_userid = order_items_stmt:bind_create(sysbench.sql.type.BIGINT)
        order_items_stmt:bind_param(oi_order_id, oi_item_id, oi_item_count, oi_userid)
end

function create_new_order(address, userid)
        ord_userid:set(userid)
        ord_delivery_name:set(address[1])
        ord_delivery_street_address:set(address[2])
        ord_delivery_appartment_no:set(address[3])
        ord_delivery_city:set(address[4])
        ord_delivery_country:set(address[5])
        ord_delivery_pincode:set(tostring(address[6]))
        ord_delivery_contact:set(tonumber(address[7]))

        order_stmt:execute()
        -- lastval() returns the value most recently generated by an
        -- IDENTITY/serial column in this session, which is order_id from
        -- the INSERT above. con:query() uses PQexec (not a prepared
        -- statement), so the result is always plain text, unlike
        -- fetch_row() on a prepared statement's result.
        local id_result = con:query("SELECT lastval()")
        return tonumber(id_result:fetch_row()[1])
end


function add_item_to_order(orderid, item_id ,userid)
        local item_count = sysbench.rand.pareto(1, 10)

        oi_order_id:set(orderid)
        oi_item_id:set(item_id)
        oi_item_count:set(item_count)
        oi_userid:set(userid)
        order_items_stmt:execute()

        inv_item_count:set(item_count)
        inv_inventory_id:set(item_id)
        inventory_stmt:execute()
end
function thread_init()
        drv = sysbench.sql.driver()
        con = drv:connect()

        prepare_statements()
end

function thread_done()
        order_stmt:close()
        inventory_stmt:close()
        order_items_stmt:close()

        con:disconnect()
end

function event()

        
        local inventory_scale = sysbench.opt.inventory_scale
        local num_items = sysbench.opt.items_per_order
        local user_scale = sysbench.opt.user_scale

        local userid = sysbench.rand.uniform(1, user_scale)

        cart = {}
        for i=1,num_items do
                -- get a new item to be added to order

                local item_selected = sysbench.rand.uniform(1, inventory_scale)

                cart[i] = item_selected
        end

        local address = generate_new_address()
        if not sysbench.opt.skip_trx then
                con:query("BEGIN")
        end
        local orderid = create_new_order(address,userid)

        -- Loop through the cart and add items to the order
        -- add_item_to_order performs database operations.
        -- We use a separate loop, so that we can delay a new transaction as much as possible
        for i=1,num_items do
                add_item_to_order(orderid, cart[i] ,userid)
        end

        if not sysbench.opt.skip_trx then
                con:query("COMMIT")
        end
end


