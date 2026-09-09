DROP TABLE IF EXISTS users;
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS order_items;
DROP TABLE IF EXISTS item_inventory_striping_config;
DROP TABLE IF EXISTS item_inventory_striped;
DROP TABLE IF EXISTS item_inventory;
DROP TABLE IF EXISTS item_category;
DROP TABLE IF EXISTS availability_check;
DROP TABLE IF EXISTS address;

CREATE TABLE address (
    address_id bigint NOT NULL GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    userid bigint,
    contact_name character varying(200),
    street_address character varying(200),
    appartment_no character varying(50),
    city character varying(100),
    pincode character varying(10),
    country character varying(100),
    contact bigint
);

CREATE TABLE availability_check (
    dttm timestamp without time zone
);


CREATE TABLE item_category (
    category_id integer NOT NULL GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    category_name character varying(20) NOT NULL
);

CREATE TABLE item_inventory (
    inventory_id bigint NOT NULL GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    item_name character varying(255) NOT NULL,
    item_count integer,
    item_category integer,
    dttm timestamp without time zone,
    popularity_rank bigint
);
-- This table is intentionally kept separate to demonstrate how to reduce
-- contention on updates. Instead of updating a single item_inventory row's
-- item_count on every order, the same item's inventory count is split
-- ("striped") across multiple rows (see item_inventory_striping_config for
-- how many stripes each item gets). Writers pick one stripe row at random,
-- spreading concurrent UPDATEs across rows instead of serializing on one.
CREATE TABLE item_inventory_striped (
    idpk bigint NOT NULL GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    inventory_id bigint NOT NULL,
    item_name character varying(255) NOT NULL,
    item_count integer,
    item_category integer,
    dttm timestamp without time zone,
    popularity_rank bigint,
    item_stripe_id int DEFAULT '1'

);

-- Tracks how many stripe rows exist in item_inventory_striped for each
-- inventory_id. Populated by copy_item_inventory_to_striped.sh.
CREATE TABLE item_inventory_striping_config (
    inventory_id bigint NOT NULL PRIMARY KEY,
    stripe_count int NOT NULL DEFAULT 20
);

CREATE TABLE order_items (
    order_items_idpk bigint NOT NULL GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id bigint,
    item_id bigint,
    item_count integer,
    userid integer,
    order_dttm timestamp without time zone
);

CREATE TABLE orders (
    order_id bigint NOT NULL GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    userid integer,
    delivery_name character varying(200),
    delivery_street_address character varying(200),
    delivery_appartment_no character varying(50),
    delivery_city character varying(100),
    delivery_country character varying(100),
    delivery_pincode character varying(10),
    delivery_contact bigint,
    order_dttm timestamp without time zone,
    order_status character varying(20),
    order_status_dttm timestamp without time zone
);


CREATE TABLE users (
    id bigint NOT NULL GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    username character varying(100) NOT NULL,
    password_hash character varying(100),
    first_name text,
    last_name text,
    date_of_birth date,
    default_address bigint
);

CREATE INDEX idx_address_userid ON address USING btree (userid);
CREATE INDEX idx_inventory_rank ON item_inventory USING btree (item_category, popularity_rank DESC);
CREATE INDEX idx_item_category ON item_inventory USING btree (item_category);
CREATE INDEX idx_order_item_orderid ON order_items USING btree (order_id);
CREATE INDEX idx_order_item_user_dttm ON order_items USING btree (userid, order_dttm);
CREATE INDEX idx_order_user_dttm ON orders USING btree (userid, order_dttm);

CREATE INDEX idx_inventory_striped_rank ON item_inventory_striped USING btree (item_category, popularity_rank DESC);
CREATE UNIQUE INDEX unq_idx_inventory_stripe ON item_inventory_striped USING btree (inventory_id, item_stripe_id);


insert into item_category (category_name) values ('footwear');
insert into item_category (category_name) values ('clothes');
insert into item_category (category_name) values ('electronics');
insert into item_category (category_name) values ('kids');
insert into item_category (category_name) values ('food');
insert into item_category (category_name) values ('furniture');
insert into item_category (category_name) values ('cosmetics');
insert into item_category (category_name) values ('cleaning');
insert into item_category (category_name) values ('hardware and tools');
insert into item_category (category_name) values ('home decor');
