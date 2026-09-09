if sysbench.cmdline.command == nil then
   error("Command is required. Supported commands: run")
end

-- Uses a prepared statement with bound parameters (rather than string
-- interpolation) so generated values can never be interpreted as SQL,
-- regardless of what characters end up in a random charset.
local insert_stmt = "INSERT INTO users (username, password_hash, first_name, last_name, date_of_birth, default_address) " ..
    "VALUES (?, ?, ?, ?, to_timestamp(?)::date, NULL)"

local stmt
local param_username, param_password_hash, param_first_name, param_last_name, param_date_of_birth


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

function generate_password_hash()
        local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz1234567890"
        local pswd_hash = create_random_string(chars, 70,100)
        return pswd_hash
end

function generate_user_name()
        local chars = "abcdefghijklmnopqrstuvwxyz"
        local nums='0123456789'
        local special_char = "_."
        -- Only RFC 2606 reserved domains/subdomains are used here (example.com,
        -- example.org, example.net) so generated addresses can never collide
        -- with a real, registrable domain.
        local domains = {'@example.com','@example.org','@example.net','@mail.example.com','@sub.example.org','@test.example.net','@users.example.com'}
        local str1 = sysbench.rand.string(string.rep("@",sysbench.rand.uniform(8,10)))
        local str2 = create_random_string(chars, 4, 8)
        local str3 = create_random_string(special_char,0,1)
        local str4 = create_random_string(nums,1,3)
        local str5 = create_random_string(chars, 2,4)
        local name = str1 .. str2 .. str3 .. str4 .. str5
        local domain_selector = sysbench.rand.uniform(1, 7)
        local email = name .. domains[domain_selector]
        return email
end


function prepare_statements()
        stmt = con:prepare(insert_stmt)

        param_username = stmt:bind_create(sysbench.sql.type.VARCHAR, 100)
        param_password_hash = stmt:bind_create(sysbench.sql.type.VARCHAR, 100)
        param_first_name = stmt:bind_create(sysbench.sql.type.VARCHAR, 255)
        param_last_name = stmt:bind_create(sysbench.sql.type.VARCHAR, 255)
        param_date_of_birth = stmt:bind_create(sysbench.sql.type.DOUBLE)

        stmt:bind_param(param_username, param_password_hash, param_first_name, param_last_name, param_date_of_birth)
end

function execute_insert(username, password_hash, first_name, last_name, date_of_birth)
        param_username:set(username)
        param_password_hash:set(password_hash)
        param_first_name:set(first_name)
        param_last_name:set(last_name)
        param_date_of_birth:set(date_of_birth)

        stmt:execute()
end


function thread_init()

        drv = sysbench.sql.driver()
        con = drv:connect()

        prepare_statements()
end

function thread_done()

        stmt:close()
        con:disconnect()
end


function event()

        local username = generate_user_name()
        local password_hash =  generate_password_hash()

        local alphabets = "abcdefghijklmnopqrstuvwxyz"

        local first_name = create_random_string(alphabets, 8, 30)
        local last_name = create_random_string(alphabets, 5, 60 )
        date_of_birth = sysbench.rand.gaussian(0,1041379200)

        if not sysbench.opt.skip_trx then
                con:query("BEGIN")
        end

        execute_insert(username, password_hash, first_name, last_name, date_of_birth)

        if not sysbench.opt.skip_trx then
                con:query("COMMIT")
        end
end
