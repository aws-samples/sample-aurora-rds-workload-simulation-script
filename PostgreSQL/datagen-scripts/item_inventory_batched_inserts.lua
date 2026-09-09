sysbench.cmdline.options = {
    batch_size = {"Number of rows to be inserted per transaction ", 1000}
}

if sysbench.cmdline.command == nil then
   error("Command is required. Supported commands: run")
end

local insert_stmt = "INSERT INTO item_inventory (item_name, item_count, item_category, dttm) VALUES"

-- Unlike the other data generation scripts in this repo (which use
-- con:prepare()/bind_param() for parameterized inserts), this script builds
-- a multi-row batch INSERT via string.format() to benchmark bulk-insert
-- throughput, since sysbench's PgSQL prepared-statement API does not
-- support binding a variable-length list of rows to a single statement.
--
-- This is safe ONLY because item_name is restricted to the fixed charset
-- 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' (see create_random_name() below) -- there is
-- no quote, backslash, or other SQL metacharacter it can ever contain. This
-- charset restriction is a REQUIRED SECURITY CONTROL, not a style choice:
-- if you widen the charset or source item_name from any external/user input,
-- you must switch this script to bound parameters (as the other scripts do)
-- to avoid SQL injection.
local values_list =  "('%s', %d, %d,  current_timestamp)"

function create_random_string(charSet, minlenght, length)
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

function create_random_name()
        local chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
        local name1 = create_random_string(chars, 8, 20)
        local name2 = create_random_string(chars, 8, 15)
        local name3 = create_random_string(chars, 0, 9)
        return name1 .. ' ' .. name2 .. ' ' .. name3
end



function execute_batch_insert(batch_size, item_name_list, item_count_list, item_category_list)

        query_txt = insert_stmt
        for i=1,batch_size do
                query_txt = query_txt .. string.format(values_list,item_name_list[i],item_count_list[i],item_category_list[i])
                if i<batch_size then
                        query_txt = query_txt .. ','
                end
        end

        con:query(query_txt)

end

function thread_init()

        drv = sysbench.sql.driver()
        con = drv:connect()
end

function thread_done()

        con:disconnect()
end

function event()

        if not sysbench.opt.skip_trx then
                con:query("BEGIN")
        end
        category_list = {}
        item_name_list = {}
        item_count_list = {}
        local batch_size = sysbench.opt.batch_size

        for i=1,batch_size do

                category_list[i] = sysbench.rand.uniform(1,10)
                item_name_list[i] = create_random_name()
                -- item_count is bounded to [100000, 100000000] per row.
                item_count_list[i] = sysbench.rand.gaussian(100000, 100000000)

        end

        execute_batch_insert(batch_size, item_name_list, item_count_list, category_list)

        if not sysbench.opt.skip_trx then
                con:query("COMMIT")
        end
end
