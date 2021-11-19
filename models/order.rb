# Public: Stores associated shopify order info
class Order < ApplicationRecord
  belongs_to    :user
  has_many      :sales
  has_many      :refunds
  has_many      :order_state_logs, as: :order
  has_many      :order_transactions, as: :order

  after_save    :update_logs

  STATUSES = ['new', 'in_progress', 'ready', 'fulfilled', 'partially_fulfilled', 'fulfill_cancelled', 'cancelled']

  scope :shopify, ->(shopify_order_id) {
    where(shopify_order_id: shopify_order_id)
  }

  scope :created_before, ->(age) {
    where('created_at < :age', age: age)
  }

  scope :created_after, ->(age) {
    where('created_at >= :age', age: age)
  }

  scope :between, ->(from_date, to_date) {
    where(created_at: from_date.beginning_of_day..to_date.end_of_day)
  }

  validates :status, inclusion: { in: STATUSES }, presence: true
  validates :shopify_order_id, uniqueness: true, presence: true
  validates :stripe_charge_id, uniqueness: true, allow_nil: true
  validates :paypal_charge_id, uniqueness: true, allow_nil: true

  def self.next_status(status)
    if status == 'in_progress'
      'ready'
    elsif status == 'new'
      'in_progress'
    elsif status == 'ready'
      'fulfilled'
    end
  end

  def self.create_from_shopify_order(s_order)
    user = User.find_by(email: s_order.email)

    if s_order.respond_to?(:customer)
      customer_id = s_order.customer.id
      first_name = s_order.customer.first_name
      last_name = s_order.customer.last_name
    end

    if s_order.respond_to? :order_status_url
      order_status_url = s_order.order_status_url
    end

    Order.create(
      shopify_order_id: s_order.id,
      status: 'new',
      name: s_order.name,
      amount: s_order.total_price,
      amount_charged: s_order.total_price,
      user_id: user.try(:id),
      email: s_order.email,
      customer_id: customer_id,
      first_name: first_name,
      last_name: last_name,
      shopify_status_url: order_status_url,
      fulfillment_payload: s_order.fulfillments,
      refunds_payload: s_order.refunds,
      created_at: s_order.created_at,
      updated_at: Time.zone.now
    )
  end

  def update_with_shopify_order(s_order)
    if s_order.respond_to?(:customer)
      customer_id = s_order.customer.id
      first_name = s_order.customer.first_name
      last_name = s_order.customer.last_name
    end

    if s_order.respond_to? :order_status_url
      order_status_url = s_order.order_status_url
    end

    assign_attributes(
      email: s_order.email,
      customer_id: customer_id,
      first_name: first_name,
      last_name: last_name,
      shopify_status_url: order_status_url
    )

    save
  end

  def from_third_party_app?
    order_payload && order_payload['third_party_app'] && order_payload['third_party_app'].include?('RageOn Connect')
  end

  def shopify_order
    ShopifyAPI::Order.find(shopify_order_id)
  end

  def charged_with_paypal?
    paypal_charge_id.present?
  end

  def charged_with_stripe?
    stripe_charge_id.present?
  end

  def update_logs
    if status_was != status || id_changed?
      order_state_logs.create(
        shopify_order_id: shopify_order_id,
        previous_state: OrderState.find_by(key: status_was),
        current_state: OrderState.find_by(key: status),
        source: 'ROM'
      )
    end
  rescue => error
    Rails.logger.error error
    Rails.logger.error error.backtrace
  ensure
    true
  end
end
