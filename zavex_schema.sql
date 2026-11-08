-- =====================================================================
-- ZAVEX — Database schema (PostgreSQL / Supabase)
-- Run in: Supabase Dashboard > SQL Editor > New query > paste > Run
-- Money: EGP, numeric(12,2). Bilingual fields: *_ar / *_en.
-- Orders are created ONLY through place_order() so prices, stock and
-- coupons are always computed on the server.
-- =====================================================================

create extension if not exists "pgcrypto";

-- ---------- helpers ----------
create or replace function set_updated_at() returns trigger
language plpgsql as $$ begin new.updated_at = now(); return new; end $$;

-- ---------- admins & permissions ----------
create table admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  role text not null default 'staff' check (role in ('owner','manager','staff')),
  -- permissions: products, orders, inventory, customers, offers, content,
  -- shipping, payments, reports, settings, staff
  permissions text[] not null default '{}',
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create or replace function has_perm(p text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from admins a
    where a.user_id = auth.uid() and a.is_active
      and (a.role = 'owner' or p = any(a.permissions))
  );
$$;

-- ---------- catalog ----------
create table categories (
  id uuid primary key default gen_random_uuid(),
  slug text unique not null,
  name_ar text not null, name_en text not null,
  image_url text,
  sort_order int not null default 0,
  is_visible boolean not null default true,
  created_at timestamptz not null default now()
);

create table collections (
  id uuid primary key default gen_random_uuid(),
  slug text unique not null,
  name_ar text not null, name_en text not null,
  description_ar text, description_en text,
  image_url text,
  sort_order int not null default 0,
  is_visible boolean not null default true,
  created_at timestamptz not null default now()
);

create table suppliers (
  id uuid primary key default gen_random_uuid(),
  name text not null, phone text, email text, notes text,
  created_at timestamptz not null default now()
);

create table products (
  id uuid primary key default gen_random_uuid(),
  slug text unique not null,
  name_ar text not null, name_en text not null,
  description_ar text, description_en text,
  material text, care_instructions text,
  price numeric(12,2) not null check (price >= 0),
  sale_price numeric(12,2) check (sale_price >= 0 and sale_price <= price),
  category_id uuid references categories(id) on delete set null,
  supplier_id uuid references suppliers(id) on delete set null,
  status text not null default 'draft' check (status in ('draft','published','hidden')),
  is_new_arrival boolean not null default false,
  is_best_seller boolean not null default false,
  is_featured boolean not null default false,
  is_preorder boolean not null default false,
  is_limited_drop boolean not null default false,
  seo_title text, seo_description text,
  sold_count int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger trg_products_updated before update on products
  for each row execute function set_updated_at();
create index on products (status, created_at desc);
create index on products (category_id);

create table product_images (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references products(id) on delete cascade,
  url text not null,
  color text,                       -- optional: image belongs to a color
  sort_order int not null default 0,
  is_primary boolean not null default false
);
create index on product_images (product_id, sort_order);

-- Each color+size has its own SKU and stock
create table product_variants (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references products(id) on delete cascade,
  sku text unique not null,
  color_ar text not null, color_en text not null, color_hex text,
  size text not null,
  stock_qty int not null default 0 check (stock_qty >= 0),
  low_stock_threshold int not null default 3,
  is_active boolean not null default true,
  unique (product_id, color_en, size)
);
create index on product_variants (product_id);

create table collection_products (
  collection_id uuid references collections(id) on delete cascade,
  product_id uuid references products(id) on delete cascade,
  sort_order int not null default 0,
  primary key (collection_id, product_id)
);

-- Admin-only cost data (never exposed to customers)
create table product_costs (
  product_id uuid primary key references products(id) on delete cascade,
  raw_cost numeric(12,2) not null default 0,
  printing_cost numeric(12,2) not null default 0,
  packaging_cost numeric(12,2) not null default 0,
  manufacturing_cost numeric(12,2) not null default 0,
  shipping_cost numeric(12,2) not null default 0,
  updated_at timestamptz not null default now()
);

-- ---------- customers ----------
create table customers (
  id uuid primary key default gen_random_uuid(),
  user_id uuid unique references auth.users(id) on delete set null,
  full_name text not null,
  phone text unique not null,
  email text,
  admin_notes text,
  created_at timestamptz not null default now()
);

create table addresses (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references customers(id) on delete cascade,
  governorate text not null, city text not null, area text,
  address_line text not null, extra_phone text,
  is_default boolean not null default false
);

create table wishlist (
  customer_id uuid references customers(id) on delete cascade,
  product_id uuid references products(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (customer_id, product_id)
);

create table carts (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid references customers(id) on delete cascade,
  session_id text,
  updated_at timestamptz not null default now()
);
create table cart_items (
  cart_id uuid references carts(id) on delete cascade,
  variant_id uuid references product_variants(id) on delete cascade,
  qty int not null check (qty between 1 and 10),
  primary key (cart_id, variant_id)
);

create table reviews (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references products(id) on delete cascade,
  customer_id uuid references customers(id) on delete set null,
  rating int not null check (rating between 1 and 5),
  body text,
  is_approved boolean not null default false,
  created_at timestamptz not null default now()
);

-- ---------- shipping ----------
create table shipping_zones (
  id uuid primary key default gen_random_uuid(),
  governorate text unique not null,
  fee numeric(12,2) not null check (fee >= 0),
  free_over numeric(12,2),          -- free shipping above this subtotal
  delivery_days_min int, delivery_days_max int,
  is_active boolean not null default true
);

-- ---------- coupons & promotions ----------
create table coupons (
  id uuid primary key default gen_random_uuid(),
  code text not null,
  type text not null check (type in ('percent','fixed','free_shipping')),
  value numeric(12,2) not null default 0,
  min_order numeric(12,2) not null default 0,
  max_uses int,
  per_customer_limit int not null default 1,
  used_count int not null default 0,
  starts_at timestamptz, expires_at timestamptz,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);
create unique index coupons_code_uq on coupons (upper(code));

create table promotions (
  id uuid primary key default gen_random_uuid(),
  name_ar text not null, name_en text not null,
  description_ar text, description_en text, image_url text,
  type text not null check (type in ('percent','fixed','buy2get1','free_shipping','campaign')),
  value numeric(12,2) default 0,
  product_ids uuid[] not null default '{}',
  starts_at timestamptz, ends_at timestamptz,
  is_active boolean not null default false
);

-- ---------- orders ----------
create sequence order_number_seq start 1001;

create table orders (
  id uuid primary key default gen_random_uuid(),
  order_number text unique not null
    default ('ZX-' || nextval('order_number_seq')),
  idempotency_key text unique not null,   -- blocks duplicate submissions
  customer_id uuid references customers(id) on delete set null,
  status text not null default 'pending'
    check (status in ('pending','confirmed','processing','shipped','delivered','cancelled')),
  payment_method text not null check (payment_method in ('cod','instapay','fawry','online')),
  payment_status text not null default 'unpaid'
    check (payment_status in ('unpaid','pending_review','paid','failed','refunded')),
  ship_name text not null, ship_phone text not null, ship_extra_phone text,
  ship_governorate text not null, ship_city text not null, ship_area text,
  ship_address text not null,
  customer_notes text, internal_notes text, tracking_number text,
  subtotal numeric(12,2) not null default 0,
  discount numeric(12,2) not null default 0,
  shipping_fee numeric(12,2) not null default 0,
  total numeric(12,2) not null default 0,
  coupon_code text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger trg_orders_updated before update on orders
  for each row execute function set_updated_at();
create index on orders (status, created_at desc);
create index on orders (ship_phone);

create table order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references orders(id) on delete cascade,
  variant_id uuid references product_variants(id) on delete set null,
  product_name text not null,          -- snapshots: survive later edits
  color text not null, size text not null, sku text not null,
  unit_price numeric(12,2) not null,
  qty int not null check (qty > 0)
);
create index on order_items (order_id);

create table coupon_redemptions (
  id uuid primary key default gen_random_uuid(),
  coupon_id uuid not null references coupons(id) on delete cascade,
  order_id uuid not null references orders(id) on delete cascade,
  customer_phone text not null,
  discount numeric(12,2) not null,
  created_at timestamptz not null default now()
);

-- ---------- inventory ----------
create table inventory_logs (
  id uuid primary key default gen_random_uuid(),
  variant_id uuid not null references product_variants(id) on delete cascade,
  change_qty int not null,
  reason text not null check (reason in ('sale','purchase','adjustment','return','cancel')),
  order_id uuid references orders(id) on delete set null,
  note text, created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);
create index on inventory_logs (variant_id, created_at desc);

-- ---------- returns, notifications, settings, audit ----------
create table return_requests (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references orders(id) on delete cascade,
  type text not null check (type in ('return','exchange')),
  reason text, status text not null default 'requested'
    check (status in ('requested','approved','rejected','completed')),
  created_at timestamptz not null default now()
);

create table notifications (
  id uuid primary key default gen_random_uuid(),
  type text not null check (type in ('new_order','low_stock','out_of_stock','order_cancelled','customer_message')),
  title text not null, body text, ref_id uuid,
  is_read boolean not null default false,
  created_at timestamptz not null default now()
);

create table settings (
  key text primary key,
  value jsonb not null,
  is_public boolean not null default false,   -- public = readable by storefront
  updated_at timestamptz not null default now()
);

create table audit_log (
  id bigserial primary key,
  admin_id uuid references auth.users(id),
  action text not null, entity text, entity_id text, details jsonb,
  created_at timestamptz not null default now()
);

-- ---------- notifications from stock changes ----------
create or replace function notify_stock() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.stock_qty = 0 and old.stock_qty > 0 then
    insert into notifications(type,title,ref_id) values ('out_of_stock','Variant out of stock: '||new.sku,new.id);
  elsif new.stock_qty <= new.low_stock_threshold and old.stock_qty > new.low_stock_threshold then
    insert into notifications(type,title,ref_id) values ('low_stock','Low stock: '||new.sku,new.id);
  end if;
  return new;
end $$;
create trigger trg_stock_notify after update of stock_qty on product_variants
  for each row execute function notify_stock();

-- =====================================================================
-- place_order(): the ONLY way to create an order.
-- Prices, shipping, coupon and stock are all decided here, never by
-- the browser. Variant rows are locked (FOR UPDATE) so two buyers can't
-- take the last piece. A repeated idempotency_key returns the same order.
-- p_items    : [{"variant_id":"...","qty":2}, ...]
-- p_customer : {"name","phone","extra_phone","governorate","city","area","address"}
-- =====================================================================
create or replace function place_order(
  p_idempotency_key text, p_items jsonb, p_customer jsonb,
  p_payment_method text, p_coupon_code text default null, p_notes text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_existing orders; v_order orders; v_item record; v_var record;
  v_cust uuid; v_zone shipping_zones; v_coupon coupons;
  v_qty int; v_price numeric(12,2);
  v_subtotal numeric(12,2) := 0; v_discount numeric(12,2) := 0; v_ship numeric(12,2) := 0;
  v_phone text := btrim(p_customer->>'phone');
begin
  if p_idempotency_key is null or length(p_idempotency_key) < 8 then
    raise exception 'invalid_request';
  end if;
  select * into v_existing from orders where idempotency_key = p_idempotency_key;
  if found then
    return jsonb_build_object('order_id', v_existing.id,
      'order_number', v_existing.order_number, 'total', v_existing.total, 'duplicate', true);
  end if;

  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'empty_cart';
  end if;
  if v_phone is null or v_phone !~ '^[0-9+]{10,15}$' then raise exception 'invalid_phone'; end if;

  select * into v_zone from shipping_zones
   where governorate = p_customer->>'governorate' and is_active;
  if not found then raise exception 'shipping_unavailable'; end if;

  -- guest or logged-in customer, matched by phone
  insert into customers(user_id, full_name, phone)
  values (auth.uid(), btrim(p_customer->>'name'), v_phone)
  on conflict (phone) do update set full_name = excluded.full_name
  returning id into v_cust;

  insert into orders(idempotency_key, customer_id, payment_method, ship_name, ship_phone,
    ship_extra_phone, ship_governorate, ship_city, ship_area, ship_address, customer_notes)
  values (p_idempotency_key, v_cust, p_payment_method, btrim(p_customer->>'name'), v_phone,
    p_customer->>'extra_phone', p_customer->>'governorate', p_customer->>'city',
    p_customer->>'area', p_customer->>'address', p_notes)
  returning * into v_order;

  -- lock variants in a stable order to avoid deadlocks
  for v_item in
    select (value->>'variant_id')::uuid as variant_id, (value->>'qty')::int as qty
    from jsonb_array_elements(p_items) order by 1
  loop
    v_qty := v_item.qty;
    if v_qty is null or v_qty < 1 or v_qty > 10 then raise exception 'invalid_qty'; end if;

    select v.id, v.sku, v.color_en, v.size, v.stock_qty, v.is_active,
           p.name_en, p.price, p.sale_price, p.status, p.is_preorder
      into v_var
      from product_variants v join products p on p.id = v.product_id
     where v.id = v_item.variant_id
       for update of v;

    if not found or not v_var.is_active or v_var.status <> 'published' then
      raise exception 'variant_unavailable';
    end if;
    if v_var.stock_qty < v_qty and not v_var.is_preorder then
      raise exception 'out_of_stock:%', v_var.sku;
    end if;

    v_price := coalesce(v_var.sale_price, v_var.price);
    v_subtotal := v_subtotal + v_price * v_qty;

    insert into order_items(order_id, variant_id, product_name, color, size, sku, unit_price, qty)
    values (v_order.id, v_var.id, v_var.name_en, v_var.color_en, v_var.size, v_var.sku, v_price, v_qty);

    if not v_var.is_preorder then
      update product_variants set stock_qty = stock_qty - v_qty where id = v_var.id;
      insert into inventory_logs(variant_id, change_qty, reason, order_id)
      values (v_var.id, -v_qty, 'sale', v_order.id);
    end if;
  end loop;

  -- shipping
  v_ship := v_zone.fee;
  if v_zone.free_over is not null and v_subtotal >= v_zone.free_over then v_ship := 0; end if;

  -- coupon (validated here, on the server)
  if p_coupon_code is not null and btrim(p_coupon_code) <> '' then
    select * into v_coupon from coupons
     where upper(code) = upper(btrim(p_coupon_code)) and is_active
       and (starts_at is null or starts_at <= now())
       and (expires_at is null or expires_at > now())
       for update;
    if not found then raise exception 'coupon_invalid'; end if;
    if v_subtotal < v_coupon.min_order then raise exception 'coupon_min_order'; end if;
    if v_coupon.max_uses is not null and v_coupon.used_count >= v_coupon.max_uses then
      raise exception 'coupon_exhausted';
    end if;
    if (select count(*) from coupon_redemptions
         where coupon_id = v_coupon.id and customer_phone = v_phone) >= v_coupon.per_customer_limit then
      raise exception 'coupon_limit_reached';
    end if;

    v_discount := case v_coupon.type
      when 'percent' then round(v_subtotal * v_coupon.value / 100, 2)
      when 'fixed' then least(v_coupon.value, v_subtotal)
      else 0 end;
    if v_coupon.type = 'free_shipping' then v_ship := 0; end if;

    insert into coupon_redemptions(coupon_id, order_id, customer_phone, discount)
    values (v_coupon.id, v_order.id, v_phone, v_discount);
    update coupons set used_count = used_count + 1 where id = v_coupon.id;
  end if;

  update orders set subtotal = v_subtotal, discount = v_discount, shipping_fee = v_ship,
         total = v_subtotal - v_discount + v_ship,
         coupon_code = upper(nullif(btrim(p_coupon_code), ''))
   where id = v_order.id returning * into v_order;

  update products p set sold_count = sold_count + oi.q
    from (select v.product_id, sum(i.qty) q from order_items i
          join product_variants v on v.id = i.variant_id
          where i.order_id = v_order.id group by v.product_id) oi
   where p.id = oi.product_id;

  insert into notifications(type, title, body, ref_id)
  values ('new_order', 'New order '||v_order.order_number, 'Total: '||v_order.total||' EGP', v_order.id);

  return jsonb_build_object('order_id', v_order.id, 'order_number', v_order.order_number,
                            'total', v_order.total, 'duplicate', false);
end $$;

-- Order tracking: needs BOTH order number and phone
create or replace function track_order(p_order_number text, p_phone text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('order_number', order_number, 'status', status,
         'tracking_number', tracking_number, 'total', total, 'created_at', created_at)
  from orders where order_number = p_order_number and ship_phone = p_phone;
$$;

-- Cancel: restock + log (admin only)
create or replace function cancel_order(p_order_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if not has_perm('orders') then raise exception 'forbidden'; end if;
  if (select status from orders where id = p_order_id) in ('cancelled','delivered') then
    raise exception 'cannot_cancel';
  end if;
  for r in select variant_id, qty from order_items where order_id = p_order_id and variant_id is not null loop
    update product_variants set stock_qty = stock_qty + r.qty where id = r.variant_id;
    insert into inventory_logs(variant_id, change_qty, reason, order_id, created_by)
    values (r.variant_id, r.qty, 'cancel', p_order_id, auth.uid());
  end loop;
  update orders set status = 'cancelled' where id = p_order_id;
  insert into audit_log(admin_id, action, entity, entity_id) values (auth.uid(), 'cancel_order', 'orders', p_order_id::text);
end $$;

revoke all on function place_order, track_order from public;
grant execute on function place_order, track_order to anon, authenticated;
grant execute on function cancel_order to authenticated;

-- =====================================================================
-- Row Level Security
-- =====================================================================
do $$
declare t text;
begin
  foreach t in array array['admins','categories','collections','suppliers','products','product_images',
    'product_variants','collection_products','product_costs','customers','addresses','wishlist','carts',
    'cart_items','reviews','shipping_zones','coupons','promotions','orders','order_items',
    'coupon_redemptions','inventory_logs','return_requests','notifications','settings','audit_log']
  loop execute format('alter table %I enable row level security', t); end loop;
end $$;

-- Public (storefront) read access
create policy pub_categories on categories for select using (is_visible);
create policy pub_collections on collections for select using (is_visible);
create policy pub_products on products for select using (status = 'published');
create policy pub_images on product_images for select
  using (exists (select 1 from products p where p.id = product_id and p.status = 'published'));
create policy pub_variants on product_variants for select
  using (is_active and exists (select 1 from products p where p.id = product_id and p.status = 'published'));
create policy pub_coll_products on collection_products for select using (true);
create policy pub_shipping on shipping_zones for select using (is_active);
create policy pub_reviews on reviews for select using (is_approved);
create policy pub_promotions on promotions for select using (is_active);
create policy pub_settings on settings for select using (is_public);
create policy ins_reviews on reviews for insert to authenticated with check (is_approved = false);

-- Customers see only their own data
create policy own_customer on customers for select using (user_id = auth.uid());
create policy own_addresses on addresses for all
  using (customer_id in (select id from customers where user_id = auth.uid()))
  with check (customer_id in (select id from customers where user_id = auth.uid()));
create policy own_wishlist on wishlist for all
  using (customer_id in (select id from customers where user_id = auth.uid()))
  with check (customer_id in (select id from customers where user_id = auth.uid()));
create policy own_orders on orders for select
  using (customer_id in (select id from customers where user_id = auth.uid()));
create policy own_order_items on order_items for select
  using (order_id in (select o.id from orders o join customers c on c.id = o.customer_id where c.user_id = auth.uid()));

-- Staff access, by permission
create policy adm_self on admins for select using (user_id = auth.uid());
create policy adm_staff on admins for all using (has_perm('staff')) with check (has_perm('staff'));

do $$
declare m record;
begin
  for m in select * from (values
    ('categories','products'),('collections','content'),('suppliers','inventory'),
    ('products','products'),('product_images','products'),('product_variants','products'),
    ('collection_products','content'),('product_costs','reports'),
    ('customers','customers'),('addresses','customers'),
    ('reviews','content'),('shipping_zones','shipping'),
    ('coupons','offers'),('promotions','offers'),
    ('orders','orders'),('order_items','orders'),('coupon_redemptions','offers'),
    ('inventory_logs','inventory'),('return_requests','orders'),
    ('notifications','orders'),('settings','settings'),('audit_log','staff')
  ) as x(tbl, perm)
  loop
    execute format('create policy adm_%1$s on %1$I for all using (has_perm(%2$L)) with check (has_perm(%2$L))',
                   m.tbl, m.perm);
  end loop;
end $$;

-- =====================================================================
-- Seed: Egyptian governorates (edit fees later from the admin panel)
-- =====================================================================
insert into shipping_zones (governorate, fee, delivery_days_min, delivery_days_max) values
 ('Cairo',60,2,3),('Giza',60,2,3),('Alexandria',70,2,4),('Qalyubia',65,2,4),
 ('Dakahlia',75,3,5),('Sharqia',75,3,5),('Gharbia',75,3,5),('Monufia',75,3,5),
 ('Beheira',75,3,5),('Kafr El Sheikh',75,3,5),('Damietta',75,3,5),('Port Said',75,3,5),
 ('Ismailia',75,3,5),('Suez',75,3,5),('Fayoum',80,3,5),('Beni Suef',80,3,5),
 ('Minya',85,4,6),('Asyut',85,4,6),('Sohag',90,4,7),('Qena',90,4,7),
 ('Luxor',95,4,7),('Aswan',95,5,7),('Red Sea',100,5,7),('Matrouh',100,5,7),
 ('New Valley',110,5,8),('North Sinai',110,5,8),('South Sinai',110,5,8);

insert into settings (key, value, is_public) values
 ('brand', '{"name":"ZAVEX","tagline_en":"Wear Your Identity","tagline_ar":"ارتدِ هويتك"}', true),
 ('payment_methods', '{"cod":true,"instapay":false,"fawry":false,"online":false}', true);

-- After creating your own account in Supabase Auth, make yourself owner:
-- insert into admins (user_id, full_name, role) values ('<YOUR-AUTH-USER-ID>', 'Owner', 'owner');
