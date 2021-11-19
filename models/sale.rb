class Sale < ApplicationRecord
  include Product::Countable
  include Sale::Reports

  belongs_to :user
  belongs_to :order
  belongs_to :product, counter_cache: true
  belongs_to :parent, class_name: 'Sale'

  after_save :update_counter_cache
  # after_destroy :update_counter_cache # sales are not deleted

  has_many :refunds,      dependent: :destroy
  has_many :micro_sales,  dependent: :destroy

  has_many :sale_components,      dependent: :destroy
  has_many :sub_sales,            foreign_key: 'parent_id', class_name: 'Sale', dependent: :destroy
  has_many :sub_referral_sales,   -> { where(type: 'ReferralSale') },   foreign_key: 'parent_id', class_name: 'Sale', dependent: :destroy
  has_many :sub_sticker_sales,    -> { where(type: 'StickerSale') },    foreign_key: 'parent_id', class_name: 'Sale', dependent: :destroy
  has_many :sub_affiliate_sales,  -> { where(type: 'AffiliateSale') },  foreign_key: 'parent_id', class_name: 'Sale', dependent: :destroy

  validate :commission_should_be_less_than_100_percent
  validate :micro_sales_commission_should_be_less_than_100_percent

  REFUND_TYPE = {
    'ConnectSale'   => 'ConnectRefund',
    'StickerSale'   => 'StickerRefund',
    'ReferralSale'  => 'ReferralRefund',
    'AffiliateSale' => 'AffiliateRefund'
  }

  def refund_type
    REFUND_TYPE[type]
  end

  def recalculate_components
    super_likes_sale_ids = micro_sales.pluck(:id)
    profit_refunds = refunds.where(type: type).sum(:amount_to_deduct)
    component_hash = {
      profit_refunds: profit_refunds,
      discounts_applied: profit_refunds.positive? ? 0 : discounts_applied * quantity,
      affiliate_profit: 0,
      affiliate_refunds: 0,
      referral_profit: 0,
      referral_refunds: 0,
      stickers_profit: 0,
      stickers_refunds: 0,
      super_likes_profit: MicroSale.where(id: super_likes_sale_ids).sum(:profit),
      super_likes_refunds: -MicroRefund.where(micro_sale_id: super_likes_sale_ids).sum(:amount)
    }
    sub_sales.includes(:user, :product).each do |sub_sale|
      sub_profit = sub_sale.profit
      sub_refunds = sub_sale.refunds.sum(:amount_to_deduct)
      sub_sale.update(base_price: sub_sale.item_cost, shopify_price: sub_sale.unit_price)

      case sub_sale.type
      when 'AffiliateSale'
        component_hash[:affiliate_profit] += sub_profit
        component_hash[:affiliate_refunds] -= sub_refunds
      when 'ReferralSale'
        component_hash[:referral_profit] += sub_profit
        component_hash[:referral_refunds] -= sub_refunds
      when 'StickerSale'
        component_hash[:stickers_profit] += sub_profit
        component_hash[:stickers_refunds] -= sub_refunds
      end
    end
    component_hash.each do |key, value|
      component = sale_components.find_or_initialize_by(component_type: SaleComponent.value_of(key))
      component.update(amount: value)
    end
  end

  # WARNING make sure to do manual calculation before running this on production
  def recalculate
    if order && order.from_third_party_app?
      new_sku = variant_sku
      new_item_cost = item_cost
      micro_commission_cut = 0
    else
      variant = Variant.find_by(shopify_variant_id: variant_id)
      return false unless variant
      new_sku = variant.sku
      new_item_cost = SkuPattern.cost_method_for_sku(new_sku, user_id)
      return false if new_item_cost.zero?
      micro_commission_cut = micro_sales_commission_cut
    end
    # If you change this logic Also change it in ShopifyWebhooksController#create_user_sales
    # affiliate_commission = unit_price * 0.15
    # unit_price = unit_price - affiliate_commission

    new_profit = [(unit_price - new_item_cost) * quantity, 0].max * commission_rate
    net_profit = new_profit * (1 - micro_commission_cut)
    return unless new_sku
    update(variant_sku: new_sku, profit: net_profit, item_cost: new_item_cost, micro_sales_commission_cut: micro_commission_cut)
  end

  def pending_balance
    paid_out || created_at < user.payout_days ? 0 : creator_take
  end

  def available_balance
    !paid_out && created_at < user.payout_days ? creator_take : 0
  end

  def net_profit
    return 0 if unit_price.nil? || item_cost.nil? || quantity.nil?
    if type.nil?
      return quantity if PriceCalculatorFactory.margin_reached?(version, plan_identifier, discounts_applied, retail_price)
      if PriceCalculatorFactory.min_enforced?(version, plan_identifier)
        return [(unit_price - item_cost) * quantity, quantity].max
      end
    end
    [(unit_price - item_cost) * quantity, 0].max
  end

  def creator_take
    if profit.present? && profit.nonzero?
      profit
    else
      user.ensure_payout_account!
      c_rate = commission_rate.nil? ? user.payout_account.commission_rate : commission_rate
      net_profit * c_rate * (1 - (micro_sales_commission_cut.nil? ? 0 : micro_sales_commission_cut))
    end
  end

  private

  def commission_should_be_less_than_100_percent
    return nil if commission_rate.nil?
    return nil unless commission_rate.negative? || commission_rate > 1
    errors.add(:commission_rate, "can't be more than 100% or less than 0%")
  end

  def micro_sales_commission_should_be_less_than_100_percent
    return nil if micro_sales_commission_cut.nil?
    return nil unless micro_sales_commission_cut.negative? || micro_sales_commission_cut > 1
    errors.add(:micro_sales_commission_cut, "can't be more than 100% or less than 0%")
  end

  def update_counter_cache
    return unless user
    user.sales_count = user.product_sales.count
    user.save
  end
end
