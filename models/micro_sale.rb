class MicroSale < ApplicationRecord
  belongs_to  :sale
  belongs_to  :product
  belongs_to  :user

  has_many    :micro_refunds, dependent: :destroy

  scope :available, ->(age = 30.days.ago) {
    where('micro_sales.created_at < :age', age: age)
  }

  scope :pending, ->(age = 30.days.ago) {
    where('micro_sales.created_at >= :age', age: age)
  }

  scope :since, ->(age) {
    where('micro_sales.created_at >= :age', age: age)
  }

  scope :unpaid, -> () {
    where(paid_out: false)
  }

  scope :paid, -> () {
    where(paid_out: true)
  }

  scope :list_sales, ->(age) {
    since(age).available
  }

  scope :list_pending_sales, ->(age) {
    since(age).pending
  }

  scope :between, ->(from_date, to_date) {
    where(created_at: from_date.beginning_of_day..to_date.end_of_day)
  }

  scope :reporting, ->(from_date, to_date, current_user_id, db_current_time_zone) {
    joins('LEFT JOIN products ON products.id = micro_sales.product_id')
      .select('products.title as "title", micro_sales.profit as "amount"')
      .select("'micro_sale' as \"type\", 0 as \"quantity\", 1 as \"rate\", micro_sales.created_at #{db_current_time_zone} as \"date\"")
      .where(user_id: current_user_id).where('micro_sales.created_at >= ? AND micro_sales.created_at <= ?', from_date, to_date)
      .where('micro_sales.profit > 0')
  }

  scope :reporting_aggregated, ->(from_date, to_date, current_user_id) {
    joins('LEFT JOIN products ON products.id = micro_sales.product_id')
      .select('SUM(micro_sales.profit) as "amount"')
      .where(user_id: current_user_id).where('micro_sales.created_at >= ? AND micro_sales.created_at <= ?', from_date, to_date)
      .where('micro_sales.profit > 0')
  }
end
