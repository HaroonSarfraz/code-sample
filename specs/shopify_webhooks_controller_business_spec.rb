require 'rails_helper'
require 'transactions_helper'

RSpec.describe ShopifyWebhooksController, type: :request do
  # after(:each) do
  #   sale = Sale.first
  #   p sale
  #   puts "\nBusiness"
  #   puts '========'
  #   puts "Retail Price:  #{sale.retail_price}"
  #   puts "Price Charged: #{sale.shopify_price}"
  #   puts "Unit Price:    #{sale.unit_price}"
  #   puts "Vendor Cost:   #{sale.item_cost}"
  #   puts "Discounts:     #{sale.discounts_applied}"
  #   puts "Quantity:      #{sale.quantity}"
  #   puts "Sales:         #{Sale.pluck(:type, :profit)}"
  #   puts "Micro Sales:   #{MicroSale.pluck(:profit)}"
  # end

  describe 'POST create orders predefined calculations by internal team' do
    let(:who_referred) { FactoryBot.create(:user) }
    let(:user) { FactoryBot.create(:user) }
    let(:creator) { FactoryBot.create(:user) }
    let(:super_liker_1) { FactoryBot.create(:user) }
    let(:super_liker_2) { FactoryBot.create(:user) }
    let(:sticker_owner) { FactoryBot.create(:user) }
    let(:sticker_owner_2) { FactoryBot.create(:user) }
    let(:affiliate_owner) { FactoryBot.create(:user, id: 400) }

    let(:base_sku_tshirts) do
      FactoryBot.create(:sku_pattern,
                         name: 'T-Shirts',
                         pattern: '^[A-Z]{3}TS.+',
                         general_cost: 39.0,
                         general_ro_cost: 13.65,
                         update_identifier: 0,
                         priority: 0)
    end
    let(:enterprise_cost_structure) do
      FactoryBot.create(:cost_structure,
                         identifier: 'SAAS-Enterprise')
    end
    let(:enterprise_sku_tshirts) do
      FactoryBot.create(:sku_pattern_override,
                         sku_pattern: base_sku_tshirts,
                         cost_structure: enterprise_cost_structure,
                         general_cost: 18.0)
    end
    let(:cost_structure) do
      FactoryBot.create(:cost_structure,
                         identifier: 'SAAS-Business')
    end
    let(:user_cost_structure) do
      FactoryBot.create(:user_cost_structure,
                         user: creator,
                         cost_structure: cost_structure)
    end
    let(:sku_tshirts) do
      enterprise_sku_tshirts.reload
      user_cost_structure.reload
      FactoryBot.create(:sku_pattern_override,
                         sku_pattern: base_sku_tshirts,
                         cost_structure: cost_structure,
                         general_cost: 23.0)
    end

    let(:sticker1) do
      Sticker.create(
        id: 'b73c7788-c88a-4801-af96-2b8d4f4742ca',
        title: 'Test',
        category: 'Random',
        visibility_state: 2,
        price_type: 'fixed',
        price_value: 2.00,
        image_path: 'random_path',
        thumbnail_image_path: 'random_thumbnail_path',
        user_id: sticker_owner.id
      )
    end
    let(:sticker3) do
      Sticker.create(
        id: 'b73c7788-c88a-4902-af96-2b8d4f4742ca',
        title: 'Test',
        category: 'Random',
        visibility_state: 2,
        price_type: 'percentage',
        price_value: 10.0,
        image_path: 'random_path',
        thumbnail_image_path: 'random_thumbnail_path',
        user_id: sticker_owner_2.id
      )
    end

    let(:product) do
      product = Product.new(
        id: 101,
        user_id: creator.id,
        title: 'Test product',
        description: 'Hell yeah',
        product_type: 'T-Shirts',
        shopify_product_id: '2503811011',
        variants: [],
        created_at: Time.zone.now,
        updated_at: Time.zone.now,
        shopify_mockup_url: '',
        mockup_path: '',
        image_path: '',
        partners: false
      )
      product.save(validate: false)
      product.variants.create(
        size: 'X-Large',
        style: 'Standard',
        price: 29.99,
        sku: 'ROCTS0001UXLOSSD'
      )
      product.variants.create(
        size: 'XX-Large',
        style: 'Standard',
        price: 31.99,
        sku: 'ROCTS0001U2XOSSD'
      )
      product.variants.create(
        size: 'XX-Large',
        style: 'Premium',
        price: 34.99,
        sku: 'ROCTS0001U2XDSPR'
      )

      sku_tshirts
      product
    end

    before(:each) do
      affiliate_owner
    end

    describe 'Non ROC Orders' do
      before(:each) do
        allow(PriceCalculatorFactory).to receive(:get).and_return(PriceCalculator::Business.new)
      end

      it 'creates sale object when create order webhook of shopify is fired + Multiple Stickers sales & Referral Sale' do
        params = json_file_to_hash('webhooks_order_create_business_plan_no_discounts')
        params['created_at'] = 20.days.ago

        allow(Product).to receive(:where).and_return([product])
        allow_any_instance_of(ShopifyWebhooksController).to receive(:verify_webhook).and_return(nil)
        allow_any_instance_of(PushNotificationService).to receive(:send).and_return(nil)
        allow(ShopifyAPI::Product).to receive(:find).and_return(
          ShopifyAPI::Product.new(product_type: 'Tank Tops', variants: [{ id: '7298878211', title: 'Small' }])
        )
        expect(UpdateBalanceJob).to receive(:perform_later).twice

        user.orders.create(
          id: 10,
          shopify_order_id: 1_717_060_355,
          status: 'new',
          amount: 50.73,
          amount_charged: 50.73,
          created_at: Time.zone.now,
          updated_at: Time.zone.now,
          stripe_charge_id: '123123123123',
          order_payload: nil
        )

        creator.update(referrer_id: who_referred.id)

        SuperLike.create(product: product, user: super_liker_1)
        SuperLike.create(product: product, user: super_liker_2)

        sticker1.reload
        sticker3.reload

        post '/shopify_webhooks/order_create', params

        expect(response).to have_http_status(:success)

        expect(creator.sales.count).to eq(1)
        expect(super_liker_1.micro_sales.count).to eq(1)
        expect(super_liker_2.micro_sales.count).to eq(1)
        expect(sticker_owner.sales.count).to eq(1)
        expect(affiliate_owner.sales.count).to eq(1)
        expect(who_referred.sales.count).to eq(1)

        expect(affiliate_owner.available_balance.round(2)).to eq(0)
        expect(affiliate_owner.pending_balance.round(2)).to eq(1.8)
        expect(sticker_owner.available_balance.round(2)).to eq(0)
        expect(sticker_owner.pending_balance.round(2)).to eq(2.0)
        expect(sticker_owner_2.available_balance.round(2)).to eq(0)
        expect(sticker_owner_2.pending_balance.round(2)).to eq(1.8)
        expect(super_liker_1.available_balance.round(2)).to eq(0)
        expect(super_liker_1.pending_balance.round(2)).to eq(0.47)
        expect(super_liker_2.available_balance.round(2)).to eq(0)
        expect(super_liker_2.pending_balance.round(2)).to eq(0.47)
        expect(creator.available_balance.round(2)).to eq(0)
        expect(creator.pending_balance.round(2)).to eq(11.39)
        expect(who_referred.available_balance.round(2)).to eq(0)
        expect(who_referred.pending_balance.round(2)).to eq(1.68)

        UpdateBalanceJob.perform_now(
          [creator.id, sticker_owner.id, sticker_owner_2.id, user.id, who_referred.id,
           affiliate_owner.id, super_liker_1.id, super_liker_2.id]
        )
        creator.reload
        sticker_owner.reload
        sticker_owner_2.reload
        who_referred.reload
        affiliate_owner.reload
        super_liker_1.reload
        super_liker_2.reload

        expect(affiliate_owner.cached_available_balance.to_f).to eq(0)
        expect(affiliate_owner.cached_pending_balance.to_f).to eq(1.8)
        expect(creator.cached_available_balance.to_f).to eq(0)
        expect(creator.cached_pending_balance.to_f).to eq(11.39)
        expect(sticker_owner.cached_available_balance.to_f).to eq(0)
        expect(sticker_owner.cached_pending_balance.to_f).to eq(2)
        expect(sticker_owner_2.cached_available_balance.to_f).to eq(0)
        expect(sticker_owner_2.cached_pending_balance.to_f).to eq(1.8)
        expect(super_liker_1.cached_available_balance.to_f).to eq(0)
        expect(super_liker_1.cached_pending_balance.to_f).to eq(0.47)
        expect(super_liker_2.cached_available_balance.to_f).to eq(0)
        expect(super_liker_2.cached_pending_balance.to_f).to eq(0.47)
        expect(who_referred.cached_available_balance.to_f).to eq(0)
        expect(who_referred.cached_pending_balance.to_f).to eq(1.68)

        expect(SaleActivity.count).to eq(1)
        expect(SuperLikeSaleActivity.count).to eq(2)
        expect(StickerSaleActivity.count).to eq(2)
        expect(ReferralSaleActivity.count).to eq(1)
        expect(AffiliateSaleActivity.count).to eq(1)
        expect(SuperLikeSaleActivity.count).to eq(2)

        product.destroy

        expect(sticker_owner.sales.first.extra_data['sticker_id']).to eq(sticker1.id)
        expect(sticker_owner_2.sales.first.extra_data['sticker_id']).to eq(sticker3.id)
        expect(creator.sales.first.sub_sales.count).to eq(4)
        expect(creator.sales.first.sub_referral_sales.count).to eq(1)
        expect(creator.sales.first.sub_affiliate_sales.count).to eq(1)
        expect(creator.sales.first.sub_sticker_sales.count).to eq(2)
        expect(sticker_owner.sales.first.parent).to eq(creator.sales.first)
        expect(sticker_owner_2.sales.first.parent).to eq(creator.sales.first)
        expect(who_referred.sales.first.parent).to eq(creator.sales.first)
        expect(affiliate_owner.sales.first.parent).to eq(creator.sales.first)

        expect(MicroSale.count).to eq(2)
        expect(MicroSale.first.profit.round(2)).to eq(0.47)
        expect(MicroSale.second.profit.round(2)).to eq(0.47)
        expect(StickerSale.count).to eq(2)
        expect(StickerSale.first.profit).to eq(2.0)
        expect(StickerSale.second.profit).to eq(1.8)

        sticker_sale1 = StickerSale.first
        sticker_sale1.profit = nil
        expect(sticker_sale1.creator_take.round(2)).to eq(2.0)

        sticker_sale2 = StickerSale.second
        sticker_sale2.profit = nil
        expect(sticker_sale2.creator_take.round(2)).to eq(1.8)

        affiliate_sale = AffiliateSale.first
        affiliate_sale.profit = nil
        expect(affiliate_sale.creator_take.round(2)).to eq(1.8)

        referral_sale = ReferralSale.first
        referral_sale.profit = nil
        expect(referral_sale.creator_take.round(2)).to eq(1.68)

        sale = Sale.where(type: nil).first
        sale.profit = nil
        expect(sale.creator_take.round(2)).to eq(11.39)

        data_product_sale   = '1,39.99,0.0,39.99,23.0,16.99,100.0,16.99,0.0,3.8,1.8,11.39,All,0.0,0.0,0.0,1.68,0.94'
        data_sticker1_sale  = '1,18.0,0.0,18.0,0.0,18.0,11.0,2.0,0.0,0.0,0.0,2.0,All,0.0,0.0,0.0,0.0,0.0'
        data_sticker2_sale  = '1,18.0,0.0,18.0,0.0,18.0,10.0,1.8,0.0,0.0,0.0,1.8,All,0.0,0.0,0.0,0.0,0.0'
        data_affiliate_sale = '1,18.0,0.0,18.0,0.0,18.0,10.0,1.8,0.0,0.0,0.0,1.8,All,0.0,0.0,0.0,0.0,0.0'
        data_referral_sale  = '1,8.42,0.0,8.42,0.0,8.42,20.0,1.68,0.0,0.0,0.0,1.68,All,0.0,0.0,0.0,0.0,0.0'

        check_transactions_data(creator.api_token, data_product_sale, 'Product Sale')
        check_transactions_data(sticker_owner.api_token, data_sticker1_sale, 'Sticker Sale')
        check_transactions_data(sticker_owner_2.api_token, data_sticker2_sale, 'Sticker Sale')
        check_transactions_data(affiliate_owner.api_token, data_affiliate_sale, 'Affiliate Sale')
        check_transactions_data(who_referred.api_token, data_referral_sale, 'Referral Sale')

        params = json_file_to_hash('webhooks_refund_create_business_plan_no_discounts')

        expect(Stripe::Refund).to receive(:create)
        allow_any_instance_of(ShopifyWebhooksController).to receive(:verify_webhook).and_return(nil)
        allow_any_instance_of(Net::HTTP).to receive(:request).and_return(true)

        post '/shopify_webhooks/refund_create', params

        expect(Refund.count).to eq(5)
        expect(MicroRefund.count).to eq(2)
        expect(StickerRefund.count).to eq(2)
        expect(ReferralRefund.count).to eq(1)
        expect(AffiliateRefund.count).to eq(1)
        expect(SuperLikeRefundActivity.count).to eq(2)
        expect(StickerRefundActivity.count).to eq(2)
        expect(ReferralRefundActivity.count).to eq(1)
        expect(AffiliateRefundActivity.count).to eq(1)

        expect(affiliate_owner.available_balance.round(2) - affiliate_owner.total_deductible_refunds.round(2)).to eq(0)
        expect(affiliate_owner.pending_balance.round(2) - affiliate_owner.total_pending_refunds.round(2)).to eq(0)
        expect(sticker_owner.available_balance.round(2) - sticker_owner.total_deductible_refunds.round(2)).to eq(0)
        expect(sticker_owner.pending_balance.round(2) - sticker_owner.total_pending_refunds.round(2)).to eq(0)
        expect(sticker_owner_2.available_balance.round(2) - sticker_owner_2.total_deductible_refunds.round(2)).to eq(0)
        expect(sticker_owner_2.pending_balance.round(2) - sticker_owner_2.total_pending_refunds.round(2)).to eq(0)
        expect(super_liker_1.available_balance.round(2) - super_liker_1.total_deductible_refunds.round(2)).to eq(0)
        expect(super_liker_1.pending_balance.round(2) - super_liker_1.total_pending_refunds.round(2)).to eq(0)
        expect(super_liker_2.available_balance.round(2) - super_liker_2.total_deductible_refunds.round(2)).to eq(0)
        expect(super_liker_2.pending_balance.round(2) - super_liker_2.total_pending_refunds.round(2)).to eq(0)
        expect(creator.available_balance.round(2) - creator.total_deductible_refunds.round(2)).to eq(0)
        expect(creator.pending_balance.round(2) - creator.total_pending_refunds.round(2)).to eq(0)
        expect(who_referred.available_balance.round(2) - who_referred.total_deductible_refunds.round(2)).to eq(0)
        expect(who_referred.pending_balance.round(2) - who_referred.total_pending_refunds.round(2)).to eq(0)

        UpdateBalanceJob.perform_now(
          [creator.id, sticker_owner.id, sticker_owner_2.id, user.id, who_referred.id,
           affiliate_owner.id, super_liker_1.id, super_liker_2.id]
        )
        creator.reload
        sticker_owner.reload
        sticker_owner_2.reload
        who_referred.reload
        affiliate_owner.reload
        super_liker_1.reload
        super_liker_2.reload

        expect(creator.cached_available_balance.to_f).to eq(0)
        expect(creator.cached_pending_balance.to_f).to eq(0)
        expect(sticker_owner.cached_available_balance.to_f).to eq(0)
        expect(sticker_owner.cached_pending_balance.to_f).to eq(0)
        expect(sticker_owner_2.cached_available_balance.to_f).to eq(0)
        expect(sticker_owner_2.cached_pending_balance.to_f).to eq(0)
        expect(super_liker_1.cached_available_balance.to_f).to eq(0)
        expect(super_liker_1.cached_pending_balance.to_f).to eq(0)
        expect(super_liker_2.cached_available_balance.to_f).to eq(0)
        expect(super_liker_2.cached_pending_balance.to_f).to eq(0)
        expect(who_referred.cached_available_balance.to_f).to eq(0)
        expect(who_referred.cached_pending_balance.to_f).to eq(0)
        expect(affiliate_owner.cached_available_balance.to_f).to eq(0)
        expect(affiliate_owner.cached_pending_balance.to_f).to eq(0)

        sticker_refund1 = StickerRefund.first
        sticker_refund1.amount_to_deduct = nil
        expect(sticker_refund1.creator_deduction(sticker_sale1, nil).round(2)).to eq(2.0)

        sticker_refund2 = StickerRefund.second
        sticker_refund2.amount_to_deduct = nil
        expect(sticker_refund2.creator_deduction(sticker_sale2, nil).round(2)).to eq(1.8)

        affiliate_refund = AffiliateRefund.first
        affiliate_refund.amount_to_deduct = nil
        expect(affiliate_refund.creator_deduction(affiliate_sale, nil).round(2)).to eq(1.8)

        referral_refund = ReferralRefund.first
        referral_refund.amount_to_deduct = nil
        expect(referral_refund.creator_deduction(referral_sale, nil).round(2)).to eq(1.68)

        refund = Refund.where(type: nil).first
        refund.amount_to_deduct = nil
        expect(refund.creator_deduction(sale, nil).round(2)).to eq(11.39)

        data_product_sale   = '1,39.99,0.0,39.99,23.0,16.99,100.0,16.99,11.39,3.8,1.8,0.0,All,0.0,0.0,0.0,0.0,0.0'
        data_sticker1_sale  = '1,18.0,0.0,18.0,0.0,18.0,11.0,2.0,2.0,0.0,0.0,0.0,All,0.0,0.0,0.0,0.0,0.0'
        data_sticker2_sale  = '1,18.0,0.0,18.0,0.0,18.0,10.0,1.8,1.8,0.0,0.0,0.0,All,0.0,0.0,0.0,0.0,0.0'
        data_affiliate_sale = '1,18.0,0.0,18.0,0.0,18.0,10.0,1.8,1.8,0.0,0.0,0.0,All,0.0,0.0,0.0,0.0,0.0'
        data_referral_sale  = '1,8.42,0.0,8.42,0.0,8.42,20.0,1.68,1.68,0.0,0.0,0.0,All,0.0,0.0,0.0,0.0,0.0'

        check_transactions_data(creator.api_token, data_product_sale, 'Product Sale')
        check_transactions_data(sticker_owner.api_token, data_sticker1_sale, 'Sticker Sale')
        check_transactions_data(sticker_owner_2.api_token, data_sticker2_sale, 'Sticker Sale')
        check_transactions_data(affiliate_owner.api_token, data_affiliate_sale, 'Affiliate Sale')
        check_transactions_data(who_referred.api_token, data_referral_sale, 'Referral Sale')
      end

      it 'creates sale object when create order webhook of shopify is fired + Discounts + Multiple Stickers sales & Referral Sale' do
        params = json_file_to_hash('webhooks_order_create_business_plan_small_discounts')
        params['created_at'] = 20.days.ago

        allow(Product).to receive(:where).and_return([product])
        allow_any_instance_of(ShopifyWebhooksController).to receive(:verify_webhook).and_return(nil)
        allow_any_instance_of(PushNotificationService).to receive(:send).and_return(nil)
        allow(ShopifyAPI::Product).to receive(:find).and_return(
          ShopifyAPI::Product.new(product_type: 'Tank Tops', variants: [{ id: '7298878211', title: 'Small' }])
        )
        expect(UpdateBalanceJob).to receive(:perform_later).twice

        user.orders.create(
          id: 10,
          shopify_order_id: 1_717_060_355,
          status: 'new',
          amount: 50.73,
          amount_charged: 50.73,
          created_at: Time.zone.now,
          updated_at: Time.zone.now,
          stripe_charge_id: '123123123123',
          order_payload: nil
        )

        creator.update(referrer_id: who_referred.id)

        SuperLike.create(product: product, user: super_liker_1)
        SuperLike.create(product: product, user: super_liker_2)

        sticker1.reload
        sticker3.reload

        post '/shopify_webhooks/order_create', params

        expect(response).to have_http_status(:success)

        expect(creator.sales.count).to eq(1)
        expect(super_liker_1.micro_sales.count).to eq(1)
        expect(super_liker_2.micro_sales.count).to eq(1)
        expect(sticker_owner.sales.count).to eq(1)
        expect(affiliate_owner.sales.count).to eq(1)
        expect(who_referred.sales.count).to eq(1)

        expect(affiliate_owner.available_balance.round(2)).to eq(0)
        expect(affiliate_owner.pending_balance.round(2)).to eq(1.8)
        expect(sticker_owner.available_balance.round(2)).to eq(0)
        expect(sticker_owner.pending_balance.round(2)).to eq(2.0)
        expect(sticker_owner_2.available_balance.round(2)).to eq(0)
        expect(sticker_owner_2.pending_balance.round(2)).to eq(1.8)
        expect(super_liker_1.available_balance.round(2)).to eq(0)
        expect(super_liker_1.pending_balance.round(2)).to eq(0.37)
        expect(super_liker_2.available_balance.round(2)).to eq(0)
        expect(super_liker_2.pending_balance.round(2)).to eq(0.37)
        expect(creator.available_balance.round(2)).to eq(0)
        expect(creator.pending_balance.round(2)).to eq(7.39)
        expect(who_referred.available_balance.round(2)).to eq(0)
        expect(who_referred.pending_balance.round(2)).to eq(1.72)

        UpdateBalanceJob.perform_now(
          [creator.id, sticker_owner.id, sticker_owner_2.id, user.id, who_referred.id,
           affiliate_owner.id, super_liker_1.id, super_liker_2.id]
        )
        creator.reload
        sticker_owner.reload
        sticker_owner_2.reload
        who_referred.reload
        affiliate_owner.reload
        super_liker_1.reload
        super_liker_2.reload

        expect(affiliate_owner.cached_available_balance.to_f).to eq(0)
        expect(affiliate_owner.cached_pending_balance.to_f).to eq(1.8)
        expect(creator.cached_available_balance.to_f).to eq(0)
        expect(creator.cached_pending_balance.to_f).to eq(7.39)
        expect(sticker_owner.cached_available_balance.to_f).to eq(0)
        expect(sticker_owner.cached_pending_balance.to_f).to eq(2)
        expect(sticker_owner_2.cached_available_balance.to_f).to eq(0)
        expect(sticker_owner_2.cached_pending_balance.to_f).to eq(1.8)
        expect(super_liker_1.cached_available_balance.to_f).to eq(0)
        expect(super_liker_1.cached_pending_balance.to_f).to eq(0.37)
        expect(super_liker_2.cached_available_balance.to_f).to eq(0)
        expect(super_liker_2.cached_pending_balance.to_f).to eq(0.37)
        expect(who_referred.cached_available_balance.to_f).to eq(0)
        expect(who_referred.cached_pending_balance.to_f).to eq(1.72)

        expect(SaleActivity.count).to eq(1)
        expect(SuperLikeSaleActivity.count).to eq(2)
        expect(StickerSaleActivity.count).to eq(2)
        expect(ReferralSaleActivity.count).to eq(1)
        expect(AffiliateSaleActivity.count).to eq(1)
        expect(SuperLikeSaleActivity.count).to eq(2)

        product.destroy

        expect(sticker_owner.sales.first.extra_data['sticker_id']).to eq(sticker1.id)
        expect(sticker_owner_2.sales.first.extra_data['sticker_id']).to eq(sticker3.id)
        expect(creator.sales.first.sub_sales.count).to eq(4)
        expect(creator.sales.first.sub_referral_sales.count).to eq(1)
        expect(creator.sales.first.sub_affiliate_sales.count).to eq(1)
        expect(creator.sales.first.sub_sticker_sales.count).to eq(2)
        expect(sticker_owner.sales.first.parent).to eq(creator.sales.first)
        expect(sticker_owner_2.sales.first.parent).to eq(creator.sales.first)
        expect(who_referred.sales.first.parent).to eq(creator.sales.first)
        expect(affiliate_owner.sales.first.parent).to eq(creator.sales.first)

        expect(MicroSale.count).to eq(2)
        expect(MicroSale.first.profit.round(2)).to eq(0.37)
        expect(MicroSale.second.profit.round(2)).to eq(0.37)
        expect(StickerSale.count).to eq(2)
        expect(StickerSale.first.profit).to eq(2.0)
        expect(StickerSale.second.profit).to eq(1.8)

        sticker_sale1 = StickerSale.first
        sticker_sale1.profit = nil
        expect(sticker_sale1.creator_take.round(2)).to eq(2.0)

        sticker_sale2 = StickerSale.second
        sticker_sale2.profit = nil
        expect(sticker_sale2.creator_take.round(2)).to eq(1.8)

        affiliate_sale = AffiliateSale.first
        affiliate_sale.profit = nil
        expect(affiliate_sale.creator_take.round(2)).to eq(1.8)

        referral_sale = ReferralSale.first
        referral_sale.profit = nil
        expect(referral_sale.creator_take.round(2)).to eq(1.72)

        sale = Sale.where(type: nil).first
        sale.profit = nil
        expect(sale.creator_take.round(2)).to eq(7.39)

        data_product_sale   = '1,39.99,4.0,35.99,23.0,12.99,100.0,12.99,0.0,3.8,1.8,7.39,All,0.0,0.0,0.0,1.72,0.74'
        data_sticker1_sale  = '1,18.0,0.0,18.0,0.0,18.0,11.0,2.0,0.0,0.0,0.0,2.0,All,0.0,0.0,0.0,0.0,0.0'
        data_sticker2_sale  = '1,18.0,0.0,18.0,0.0,18.0,10.0,1.8,0.0,0.0,0.0,1.8,All,0.0,0.0,0.0,0.0,0.0'
        data_affiliate_sale = '1,18.0,0.0,18.0,0.0,18.0,10.0,1.8,0.0,0.0,0.0,1.8,All,0.0,0.0,0.0,0.0,0.0'
        data_referral_sale  = '1,8.61,0.0,8.61,0.0,8.61,20.0,1.72,0.0,0.0,0.0,1.72,All,0.0,0.0,0.0,0.0,0.0'

        check_transactions_data(creator.api_token, data_product_sale, 'Product Sale')
        check_transactions_data(sticker_owner.api_token, data_sticker1_sale, 'Sticker Sale')
        check_transactions_data(sticker_owner_2.api_token, data_sticker2_sale, 'Sticker Sale')
        check_transactions_data(affiliate_owner.api_token, data_affiliate_sale, 'Affiliate Sale')
        check_transactions_data(who_referred.api_token, data_referral_sale, 'Referral Sale')

        params = json_file_to_hash('webhooks_refund_create_business_plan_small_discounts')

        expect(Stripe::Refund).to receive(:create)
        allow_any_instance_of(ShopifyWebhooksController).to receive(:verify_webhook).and_return(nil)
        allow_any_instance_of(Net::HTTP).to receive(:request).and_return(true)

        post '/shopify_webhooks/refund_create', params

        expect(Refund.count).to eq(5)
        expect(MicroRefund.count).to eq(2)
        expect(StickerRefund.count).to eq(2)
        expect(ReferralRefund.count).to eq(1)
        expect(AffiliateRefund.count).to eq(1)
        expect(SuperLikeRefundActivity.count).to eq(2)
        expect(StickerRefundActivity.count).to eq(2)
        expect(ReferralRefundActivity.count).to eq(1)
        expect(AffiliateRefundActivity.count).to eq(1)

        expect(affiliate_owner.available_balance.round(2) - affiliate_owner.total_deductible_refunds.round(2)).to eq(0)
        expect(affiliate_owner.pending_balance.round(2) - affiliate_owner.total_pending_refunds.round(2)).to eq(0)
        expect(sticker_owner.available_balance.round(2) - sticker_owner.total_deductible_refunds.round(2)).to eq(0)
        expect(sticker_owner.pending_balance.round(2) - sticker_owner.total_pending_refunds.round(2)).to eq(0)
        expect(sticker_owner_2.available_balance.round(2) - sticker_owner_2.total_deductible_refunds.round(2)).to eq(0)
        expect(sticker_owner_2.pending_balance.round(2) - sticker_owner_2.total_pending_refunds.round(2)).to eq(0)
        expect(super_liker_1.available_balance.round(2) - super_liker_1.total_deductible_refunds.round(2)).to eq(0)
        expect(super_liker_1.pending_balance.round(2) - super_liker_1.total_pending_refunds.round(2)).to eq(0)
        expect(super_liker_2.available_balance.round(2) - super_liker_2.total_deductible_refunds.round(2)).to eq(0)
        expect(super_liker_2.pending_balance.round(2) - super_liker_2.total_pending_refunds.round(2)).to eq(0)
        expect(creator.available_balance.round(2) - creator.total_deductible_refunds.round(2)).to eq(0)
        expect(creator.pending_balance.round(2) - creator.total_pending_refunds.round(2)).to eq(0)
        expect(who_referred.available_balance.round(2) - who_referred.total_deductible_refunds.round(2)).to eq(0)
        expect(who_referred.pending_balance.round(2) - who_referred.total_pending_refunds.round(2)).to eq(0)

        UpdateBalanceJob.perform_now(
          [creator.id, sticker_owner.id, sticker_owner_2.id, user.id, who_referred.id,
           affiliate_owner.id, super_liker_1.id, super_liker_2.id]
        )
        creator.reload
        sticker_owner.reload
        sticker_owner_2.reload
        who_referred.reload
        affiliate_owner.reload
        super_liker_1.reload
        super_liker_2.reload

        expect(creator.cached_available_balance.to_f).to eq(0)
        expect(creator.cached_pending_balance.to_f).to eq(0)
        expect(sticker_owner.cached_available_balance.to_f).to eq(0)
        expect(sticker_owner.cached_pending_balance.to_f).to eq(0)
        expect(sticker_owner_2.cached_available_balance.to_f).to eq(0)
        expect(sticker_owner_2.cached_pending_balance.to_f).to eq(0)
        expect(super_liker_1.cached_available_balance.to_f).to eq(0)
        expect(super_liker_1.cached_pending_balance.to_f).to eq(0)
        expect(super_liker_2.cached_available_balance.to_f).to eq(0)
        expect(super_liker_2.cached_pending_balance.to_f).to eq(0)
        expect(who_referred.cached_available_balance.to_f).to eq(0)
        expect(who_referred.cached_pending_balance.to_f).to eq(0)
        expect(affiliate_owner.cached_available_balance.to_f).to eq(0)
        expect(affiliate_owner.cached_pending_balance.to_f).to eq(0)

        sticker_refund1 = StickerRefund.first
        sticker_refund1.amount_to_deduct = nil
        expect(sticker_refund1.creator_deduction(sticker_sale1, nil).round(2)).to eq(2.0)

        sticker_refund2 = StickerRefund.second
        sticker_refund2.amount_to_deduct = nil
        expect(sticker_refund2.creator_deduction(sticker_sale2, nil).round(2)).to eq(1.8)

        affiliate_refund = AffiliateRefund.first
        affiliate_refund.amount_to_deduct = nil
        expect(affiliate_refund.creator_deduction(affiliate_sale, nil).round(2)).to eq(1.8)

        referral_refund = ReferralRefund.first
        referral_refund.amount_to_deduct = nil
        expect(referral_refund.creator_deduction(referral_sale, nil).round(2)).to eq(1.72)

        refund = Refund.where(type: nil).first
        refund.amount_to_deduct = nil
        expect(refund.creator_deduction(sale, nil).round(2)).to eq(7.39)

        data_product_sale   = '1,39.99,4.0,35.99,23.0,12.99,100.0,12.99,7.39,3.8,1.8,0.0,All,0.0,0.0,0.0,0.0,0.0'
        data_sticker1_sale  = '1,18.0,0.0,18.0,0.0,18.0,11.0,2.0,2.0,0.0,0.0,0.0,All,0.0,0.0,0.0,0.0,0.0'
        data_sticker2_sale  = '1,18.0,0.0,18.0,0.0,18.0,10.0,1.8,1.8,0.0,0.0,0.0,All,0.0,0.0,0.0,0.0,0.0'
        data_affiliate_sale = '1,18.0,0.0,18.0,0.0,18.0,10.0,1.8,1.8,0.0,0.0,0.0,All,0.0,0.0,0.0,0.0,0.0'
        data_referral_sale  = '1,8.61,0.0,8.61,0.0,8.61,20.0,1.72,1.72,0.0,0.0,0.0,All,0.0,0.0,0.0,0.0,0.0'

        check_transactions_data(creator.api_token, data_product_sale, 'Product Sale')
        check_transactions_data(sticker_owner.api_token, data_sticker1_sale, 'Sticker Sale')
        check_transactions_data(sticker_owner_2.api_token, data_sticker2_sale, 'Sticker Sale')
        check_transactions_data(affiliate_owner.api_token, data_affiliate_sale, 'Affiliate Sale')
        check_transactions_data(who_referred.api_token, data_referral_sale, 'Referral Sale')
      end

      it 'creates sale object when create order webhook of shopify is fired + Discounts + Multiple Stickers & Referral Sale - Quantity 5' do
        params = json_file_to_hash('webhooks_order_create_business_plan_small_discounts_high_quantity')
        params['created_at'] = 20.days.ago

        allow(Product).to receive(:where).and_return([product])
        allow_any_instance_of(ShopifyWebhooksController).to receive(:verify_webhook).and_return(nil)
        allow_any_instance_of(PushNotificationService).to receive(:send).and_return(nil)
        allow(ShopifyAPI::Product).to receive(:find).and_return(
          ShopifyAPI::Product.new(product_type: 'Tank Tops', variants: [{ id: '7298878211', title: 'Small' }])
        )
        expect(UpdateBalanceJob).to receive(:perform_later).twice

        user.orders.create(
          id: 10,
          shopify_order_id: 1_717_060_355,
          status: 'new',
          amount: 210.69,
          amount_charged: 210.69,
          created_at: Time.zone.now,
          updated_at: Time.zone.now,
          stripe_charge_id: '123123123123',
          order_payload: nil
        )

        creator.update(referrer_id: who_referred.id)

        SuperLike.create(product: product, user: super_liker_1)
        SuperLike.create(product: product, user: super_liker_2)

        sticker1.reload
        sticker3.reload

        post '/shopify_webhooks/order_create', params

        expect(response).to have_http_status(:success)

        expect(creator.sales.count).to eq(1)
        expect(super_liker_1.micro_sales.count).to eq(1)
        expect(super_liker_2.micro_sales.count).to eq(1)
        expect(sticker_owner.sales.count).to eq(1)
        expect(affiliate_owner.sales.count).to eq(1)
        expect(who_referred.sales.count).to eq(1)

        expect(affiliate_owner.available_balance.round(2)).to eq(0)
        expect(affiliate_owner.pending_balance.round(2)).to eq(1.8 * 5)
        expect(sticker_owner.available_balance.round(2)).to eq(0)
        expect(sticker_owner.pending_balance.round(2)).to eq(2.0 * 5)
        expect(sticker_owner_2.available_balance.round(2)).to eq(0)
        expect(sticker_owner_2.pending_balance.round(2)).to eq(1.8 * 5)
        expect(super_liker_1.available_balance.round(2)).to eq(0)
        expect(super_liker_1.pending_balance.round(2)).to eq(0.5)
        expect(super_liker_2.available_balance.round(2)).to eq(0)
        expect(super_liker_2.pending_balance.round(2)).to eq(0.5)
        expect(creator.available_balance.round(2)).to eq(0)
        expect(creator.pending_balance).to eq(36.95)
        expect(who_referred.available_balance.round(2)).to eq(0)
        expect(who_referred.pending_balance.round(2)).to eq(9.15)

        UpdateBalanceJob.perform_now(
          [creator.id, sticker_owner.id, sticker_owner_2.id, user.id, who_referred.id,
           affiliate_owner.id, super_liker_1.id, super_liker_2.id]
        )
        creator.reload
        sticker_owner.reload
        sticker_owner_2.reload
        who_referred.reload
        affiliate_owner.reload
        super_liker_1.reload
        super_liker_2.reload

        expect(affiliate_owner.cached_available_balance.to_f).to eq(0)
        expect(affiliate_owner.cached_pending_balance.to_f).to eq(1.8 * 5)
        expect(creator.cached_available_balance.to_f).to eq(0)
        expect(creator.cached_pending_balance.to_f).to eq(36.95)
        expect(sticker_owner.cached_available_balance.to_f).to eq(0)
        expect(sticker_owner.cached_pending_balance.to_f).to eq(2 * 5)
        expect(sticker_owner_2.cached_available_balance.to_f).to eq(0)
        expect(sticker_owner_2.cached_pending_balance.to_f).to eq(1.8 * 5)
        expect(super_liker_1.cached_available_balance.to_f).to eq(0)
        expect(super_liker_1.cached_pending_balance.to_f).to eq(0.5)
        expect(super_liker_2.cached_available_balance.to_f).to eq(0)
        expect(super_liker_2.cached_pending_balance.to_f).to eq(0.5)
        expect(who_referred.cached_available_balance.to_f).to eq(0)
        expect(who_referred.cached_pending_balance.to_f).to eq(9.15)

        expect(SaleActivity.count).to eq(1)
        expect(SuperLikeSaleActivity.count).to eq(2)
        expect(StickerSaleActivity.count).to eq(2)
        expect(ReferralSaleActivity.count).to eq(1)
        expect(AffiliateSaleActivity.count).to eq(1)
        expect(SuperLikeSaleActivity.count).to eq(2)

        product.destroy

        expect(sticker_owner.sales.first.extra_data['sticker_id']).to eq(sticker1.id)
        expect(sticker_owner_2.sales.first.extra_data['sticker_id']).to eq(sticker3.id)
        expect(creator.sales.first.sub_sales.count).to eq(4)
        expect(creator.sales.first.sub_referral_sales.count).to eq(1)
        expect(creator.sales.first.sub_affiliate_sales.count).to eq(1)
        expect(creator.sales.first.sub_sticker_sales.count).to eq(2)
        expect(sticker_owner.sales.first.parent).to eq(creator.sales.first)
        expect(sticker_owner_2.sales.first.parent).to eq(creator.sales.first)
        expect(who_referred.sales.first.parent).to eq(creator.sales.first)
        expect(affiliate_owner.sales.first.parent).to eq(creator.sales.first)

        expect(MicroSale.count).to eq(2)
        expect(MicroSale.first.profit.round(2)).to eq(0.5)
        expect(MicroSale.second.profit.round(2)).to eq(0.5)
        expect(StickerSale.count).to eq(2)
        expect(StickerSale.first.profit).to eq(2.0 * 5)
        expect(StickerSale.second.profit).to eq(1.8 * 5)

        sticker_sale1 = StickerSale.first
        sticker_sale1.profit = nil
        expect(sticker_sale1.creator_take.round(2)).to eq(2.00 * 5)

        sticker_sale2 = StickerSale.second
        sticker_sale2.profit = nil
        expect(sticker_sale2.creator_take.round(2)).to eq(1.8 * 5)

        affiliate_sale = AffiliateSale.first
        affiliate_sale.profit = nil
        expect(affiliate_sale.creator_take.round(2)).to eq(1.8 * 5)

        referral_sale = ReferralSale.first
        referral_sale.profit = nil
        expect(referral_sale.creator_take.round(2)).to eq(9.15)

        sale = Sale.where(type: nil).first
        sale.profit = nil
        expect(sale.creator_take.round(2)).to eq(36.95)

        data_product_sale   = '5,199.95,20.0,179.95,115.0,64.95,100.0,64.95,0.0,19.0,9.0,36.95,All,0.0,0.0,0.0,9.15,1.0'
        data_sticker1_sale  = '5,90.0,0.0,90.0,0.0,90.0,11.0,10.0,0.0,0.0,0.0,10.0,All,0.0,0.0,0.0,0.0,0.0'
        data_sticker2_sale  = '5,90.0,0.0,90.0,0.0,90.0,10.0,9.0,0.0,0.0,0.0,9.0,All,0.0,0.0,0.0,0.0,0.0'
        data_affiliate_sale = '5,90.0,0.0,90.0,0.0,90.0,10.0,9.0,0.0,0.0,0.0,9.0,All,0.0,0.0,0.0,0.0,0.0'
        data_referral_sale  = '5,45.75,0.0,45.75,0.0,45.75,20.0,9.15,0.0,0.0,0.0,9.15,All,0.0,0.0,0.0,0.0,0.0'

        check_transactions_data(creator.api_token, data_product_sale, 'Product Sale')
        check_transactions_data(sticker_owner.api_token, data_sticker1_sale, 'Sticker Sale')
        check_transactions_data(sticker_owner_2.api_token, data_sticker2_sale, 'Sticker Sale')
        check_transactions_data(affiliate_owner.api_token, data_affiliate_sale, 'Affiliate Sale')
        check_transactions_data(who_referred.api_token, data_referral_sale, 'Referral Sale')

        params = json_file_to_hash('webhooks_refund_create_business_plan_small_discounts_high_quantity')

        expect(Stripe::Refund).to receive(:create)
        allow_any_instance_of(ShopifyWebhooksController).to receive(:verify_webhook).and_return(nil)
        allow_any_instance_of(Net::HTTP).to receive(:request).and_return(true)

        post '/shopify_webhooks/refund_create', params

        expect(Refund.count).to eq(5)
        expect(MicroRefund.count).to eq(2)
        expect(StickerRefund.count).to eq(2)
        expect(ReferralRefund.count).to eq(1)
        expect(AffiliateRefund.count).to eq(1)
        expect(SuperLikeRefundActivity.count).to eq(2)
        expect(StickerRefundActivity.count).to eq(2)
        expect(ReferralRefundActivity.count).to eq(1)
        expect(AffiliateRefundActivity.count).to eq(1)

        expect(affiliate_owner.available_balance.round(2) - affiliate_owner.total_deductible_refunds.round(2)).to eq(0)
        expect(affiliate_owner.pending_balance.round(2) - affiliate_owner.total_pending_refunds.round(2)).to eq(0)
        expect(sticker_owner.available_balance.round(2) - sticker_owner.total_deductible_refunds.round(2)).to eq(0)
        expect(sticker_owner.pending_balance.round(2) - sticker_owner.total_pending_refunds.round(2)).to eq(0)
        expect(sticker_owner_2.available_balance.round(2) - sticker_owner_2.total_deductible_refunds.round(2)).to eq(0)
        expect(sticker_owner_2.pending_balance.round(2) - sticker_owner_2.total_pending_refunds.round(2)).to eq(0)
        expect(super_liker_1.available_balance.round(2) - super_liker_1.total_deductible_refunds.round(2)).to eq(0)
        expect(super_liker_1.pending_balance.round(2) - super_liker_1.total_pending_refunds.round(2)).to eq(0)
        expect(super_liker_2.available_balance.round(2) - super_liker_2.total_deductible_refunds.round(2)).to eq(0)
        expect(super_liker_2.pending_balance.round(2) - super_liker_2.total_pending_refunds.round(2)).to eq(0)
        expect(creator.available_balance.round(2) - creator.total_deductible_refunds.round(2)).to eq(0)
        expect(creator.pending_balance.round(2) - creator.total_pending_refunds.round(2)).to eq(0)
        expect(who_referred.available_balance.round(2) - who_referred.total_deductible_refunds.round(2)).to eq(0)
        expect(who_referred.pending_balance.round(2) - who_referred.total_pending_refunds.round(2)).to eq(0)

        UpdateBalanceJob.perform_now(
          [creator.id, sticker_owner.id, sticker_owner_2.id, user.id, who_referred.id,
           affiliate_owner.id, super_liker_1.id, super_liker_2.id]
        )
        creator.reload
        sticker_owner.reload
        sticker_owner_2.reload
        who_referred.reload
        affiliate_owner.reload
        super_liker_1.reload
        super_liker_2.reload

        expect(creator.cached_available_balance.to_f).to eq(0)
        expect(creator.cached_pending_balance.to_f).to eq(0)
        expect(sticker_owner.cached_available_balance.to_f).to eq(0)
        expect(sticker_owner.cached_pending_balance.to_f).to eq(0)
        expect(sticker_owner_2.cached_available_balance.to_f).to eq(0)
        expect(sticker_owner_2.cached_pending_balance.to_f).to eq(0)
        expect(super_liker_1.cached_available_balance.to_f).to eq(0)
        expect(super_liker_1.cached_pending_balance.to_f).to eq(0)
        expect(super_liker_2.cached_available_balance.to_f).to eq(0)
        expect(super_liker_2.cached_pending_balance.to_f).to eq(0)
        expect(who_referred.cached_available_balance.to_f).to eq(0)
        expect(who_referred.cached_pending_balance.to_f).to eq(0)
        expect(affiliate_owner.cached_available_balance.to_f).to eq(0)
        expect(affiliate_owner.cached_pending_balance.to_f).to eq(0)

        sticker_refund1 = StickerRefund.first
        sticker_refund1.amount_to_deduct = nil
        expect(sticker_refund1.creator_deduction(sticker_sale1, nil).round(2)).to eq(2.0 * 5)

        sticker_refund2 = StickerRefund.second
        sticker_refund2.amount_to_deduct = nil
        expect(sticker_refund2.creator_deduction(sticker_sale2, nil).round(2)).to eq(1.8 * 5)

        affiliate_refund = AffiliateRefund.first
        affiliate_refund.amount_to_deduct = nil
        expect(affiliate_refund.creator_deduction(affiliate_sale, nil).round(2)).to eq(1.8 * 5)

        referral_refund = ReferralRefund.first
        referral_refund.amount_to_deduct = nil
        expect(referral_refund.creator_deduction(referral_sale, nil).round(2)).to eq(9.15)

        refund = Refund.where(type: nil).first
        refund.amount_to_deduct = nil
        expect(refund.creator_deduction(sale, nil).round(2)).to eq(36.95)

        data_product_sale   = '5,199.95,20.0,179.95,115.0,64.95,100.0,64.95,36.95,19.0,9.0,0.0,All,0.0,0.0,0.0,0.0,0.0'
        data_sticker1_sale  = '5,90.0,0.0,90.0,0.0,90.0,11.0,10.0,10.0,0.0,0.0,0.0,All,0.0,0.0,0.0,0.0,0.0'
        data_sticker2_sale  = '5,90.0,0.0,90.0,0.0,90.0,10.0,9.0,9.0,0.0,0.0,0.0,All,0.0,0.0,0.0,0.0,0.0'
        data_affiliate_sale = '5,90.0,0.0,90.0,0.0,90.0,10.0,9.0,9.0,0.0,0.0,0.0,All,0.0,0.0,0.0,0.0,0.0'
        data_referral_sale  = '5,45.75,0.0,45.75,0.0,45.75,20.0,9.15,9.15,0.0,0.0,0.0,All,0.0,0.0,0.0,0.0,0.0'

        # p Sale.first.sale_components.collect { |sc| [sc.component_type, sc.transaction_type, sc.amount] }
        check_transactions_data(creator.api_token, data_product_sale, 'Product Sale')
        check_transactions_data(sticker_owner.api_token, data_sticker1_sale, 'Sticker Sale')
        check_transactions_data(sticker_owner_2.api_token, data_sticker2_sale, 'Sticker Sale')
        check_transactions_data(affiliate_owner.api_token, data_affiliate_sale, 'Affiliate Sale')
        check_transactions_data(who_referred.api_token, data_referral_sale, 'Referral Sale')
      end

      it 'creates sale object when create order webhook of shopify is fired + Discounts (Over 35%) + Multiple Stickers & Referral Sale' do
        params = json_file_to_hash('webhooks_order_create_business_plan_high_discounts')
        params['created_at'] = 20.days.ago

        allow(Product).to receive(:where).and_return([product])
        allow_any_instance_of(ShopifyWebhooksController).to receive(:verify_webhook).and_return(nil)
        allow_any_instance_of(PushNotificationService).to receive(:send).and_return(nil)
        allow(ShopifyAPI::Product).to receive(:find).and_return(
          ShopifyAPI::Product.new(product_type: 'Tank Tops', variants: [{ id: '7298878211', title: 'Small' }])
        )
        expect(UpdateBalanceJob).to receive(:perform_later).twice

        user.orders.create(
          id: 10,
          shopify_order_id: 1_717_060_355,
          status: 'new',
          amount: 50.73,
          amount_charged: 50.73,
          created_at: Time.zone.now,
          updated_at: Time.zone.now,
          stripe_charge_id: '123123123123',
          order_payload: nil
        )

        creator.update(referrer_id: who_referred.id)

        SuperLike.create(product: product, user: super_liker_1)
        SuperLike.create(product: product, user: super_liker_2)

        sticker1.reload
        sticker3.reload

        post '/shopify_webhooks/order_create', params

        expect(response).to have_http_status(:success)

        expect(creator.sales.count).to eq(1)
        expect(super_liker_1.micro_sales.count).to eq(0)
        expect(super_liker_2.micro_sales.count).to eq(0)
        expect(sticker_owner.sales.count).to eq(1)
        expect(affiliate_owner.sales.count).to eq(1)
        expect(who_referred.sales.count).to eq(1)

        expect(affiliate_owner.available_balance.round(2)).to eq(0)
        expect(affiliate_owner.pending_balance.round(2)).to eq(1.8)
        expect(sticker_owner.available_balance.round(2)).to eq(0)
        expect(sticker_owner.pending_balance.round(2)).to eq(2.0)
        expect(sticker_owner_2.available_balance.round(2)).to eq(0)
        expect(sticker_owner_2.pending_balance.round(2)).to eq(1.8)
        expect(super_liker_1.available_balance.round(2)).to eq(0)
        expect(super_liker_1.pending_balance.round(2)).to eq(0.00)
        expect(super_liker_2.available_balance.round(2)).to eq(0)
        expect(super_liker_2.pending_balance.round(2)).to eq(0.00)
        expect(creator.available_balance.round(2)).to eq(0)
        expect(creator.pending_balance.round(2)).to eq(1.0)
        expect(who_referred.available_balance.round(2)).to eq(0)
        expect(who_referred.pending_balance.round(2)).to eq(1.13)

        UpdateBalanceJob.perform_now(
          [creator.id, sticker_owner.id, sticker_owner_2.id, user.id, who_referred.id,
           affiliate_owner.id, super_liker_1.id, super_liker_2.id]
        )
        creator.reload
        sticker_owner.reload
        sticker_owner_2.reload
        who_referred.reload
        affiliate_owner.reload
        super_liker_1.reload
        super_liker_2.reload

        expect(affiliate_owner.cached_available_balance.to_f).to eq(0)
        expect(affiliate_owner.cached_pending_balance.to_f).to eq(1.8)
        expect(creator.cached_available_balance.to_f).to eq(0)
        expect(creator.cached_pending_balance.to_f).to eq(1.0)
        expect(sticker_owner.cached_available_balance.to_f).to eq(0)
        expect(sticker_owner.cached_pending_balance.to_f).to eq(2)
        expect(sticker_owner_2.cached_available_balance.to_f).to eq(0)
        expect(sticker_owner_2.cached_pending_balance.to_f).to eq(1.8)
        expect(super_liker_1.cached_available_balance.to_f).to eq(0)
        expect(super_liker_1.cached_pending_balance.to_f).to eq(0.0)
        expect(super_liker_2.cached_available_balance.to_f).to eq(0)
        expect(super_liker_2.cached_pending_balance.to_f).to eq(0.0)
        expect(who_referred.cached_available_balance.to_f).to eq(0)
        expect(who_referred.cached_pending_balance.to_f).to eq(1.13)

        expect(SaleActivity.count).to eq(0)
        expect(SuperLikeSaleActivity.count).to eq(0)
        expect(StickerSaleActivity.count).to eq(2)
        expect(ReferralSaleActivity.count).to eq(1)
        expect(AffiliateSaleActivity.count).to eq(1)

        product.destroy

        expect(sticker_owner.sales.first.extra_data['sticker_id']).to eq(sticker1.id)
        expect(sticker_owner_2.sales.first.extra_data['sticker_id']).to eq(sticker3.id)
        expect(creator.sales.first.sub_sales.count).to eq(4)
        expect(creator.sales.first.sub_referral_sales.count).to eq(1)
        expect(creator.sales.first.sub_affiliate_sales.count).to eq(1)
        expect(creator.sales.first.sub_sticker_sales.count).to eq(2)
        expect(sticker_owner.sales.first.parent).to eq(creator.sales.first)
        expect(sticker_owner_2.sales.first.parent).to eq(creator.sales.first)
        expect(who_referred.sales.first.parent).to eq(creator.sales.first)
        expect(affiliate_owner.sales.first.parent).to eq(creator.sales.first)

        expect(MicroSale.count).to eq(0)
        expect(StickerSale.count).to eq(2)
        expect(StickerSale.first.profit).to eq(2.0)
        expect(StickerSale.second.profit).to eq(1.8)

        sticker_sale1 = StickerSale.first
        sticker_sale1.profit = nil
        expect(sticker_sale1.creator_take.round(2)).to eq(2.0)

        sticker_sale2 = StickerSale.second
        sticker_sale2.profit = nil
        expect(sticker_sale2.creator_take.round(2)).to eq(1.8)

        affiliate_sale = AffiliateSale.first
        affiliate_sale.profit = nil
        expect(affiliate_sale.creator_take.round(2)).to eq(1.8)

        referral_sale = ReferralSale.first
        referral_sale.profit = nil
        expect(referral_sale.creator_take.round(2)).to eq(1.13)

        sale = Sale.where(type: nil).first
        sale.profit = nil
        expect(sale.creator_take.round(2)).to eq(1.0)

        data_product_sale   = '1,39.99,14.0,25.99,23.0,2.99,100.0,2.99,0.0,3.8,1.8,1.0,All,0.0,0.0,0.0,1.13,0.0'
        data_sticker1_sale  = '1,18.0,0.0,18.0,0.0,18.0,11.0,2.0,0.0,0.0,0.0,2.0,All,0.0,0.0,0.0,0.0,0.0'
        data_sticker2_sale  = '1,18.0,0.0,18.0,0.0,18.0,10.0,1.8,0.0,0.0,0.0,1.8,All,0.0,0.0,0.0,0.0,0.0'
        data_affiliate_sale = '1,18.0,0.0,18.0,0.0,18.0,10.0,1.8,0.0,0.0,0.0,1.8,All,0.0,0.0,0.0,0.0,0.0'
        data_referral_sale  = '1,5.64,0.0,5.64,0.0,5.64,20.0,1.13,0.0,0.0,0.0,1.13,All,0.0,0.0,0.0,0.0,0.0'

        check_transactions_data(creator.api_token, data_product_sale, 'Product Sale')
        check_transactions_data(sticker_owner.api_token, data_sticker1_sale, 'Sticker Sale')
        check_transactions_data(sticker_owner_2.api_token, data_sticker2_sale, 'Sticker Sale')
        check_transactions_data(affiliate_owner.api_token, data_affiliate_sale, 'Affiliate Sale')
        check_transactions_data(who_referred.api_token, data_referral_sale, 'Referral Sale')

        params = json_file_to_hash('webhooks_refund_create_business_plan_high_discounts')

        expect(Stripe::Refund).to receive(:create)
        allow_any_instance_of(ShopifyWebhooksController).to receive(:verify_webhook).and_return(nil)
        allow_any_instance_of(Net::HTTP).to receive(:request).and_return(true)

        post '/shopify_webhooks/refund_create', params

        expect(Refund.count).to eq(5)
        expect(MicroRefund.count).to eq(0)
        expect(StickerRefund.count).to eq(2)
        expect(ReferralRefund.count).to eq(1)
        expect(AffiliateRefund.count).to eq(1)
        expect(RefundActivity.count).to eq(1)
        expect(SuperLikeRefundActivity.count).to eq(0)
        expect(StickerRefundActivity.count).to eq(2)
        expect(ReferralRefundActivity.count).to eq(1)
        expect(AffiliateRefundActivity.count).to eq(1)

        expect(affiliate_owner.available_balance.round(2) - affiliate_owner.total_deductible_refunds.round(2)).to eq(0)
        expect(affiliate_owner.pending_balance.round(2) - affiliate_owner.total_pending_refunds.round(2)).to eq(0)
        expect(sticker_owner.available_balance.round(2) - sticker_owner.total_deductible_refunds.round(2)).to eq(0)
        expect(sticker_owner.pending_balance.round(2) - sticker_owner.total_pending_refunds.round(2)).to eq(0)
        expect(sticker_owner_2.available_balance.round(2) - sticker_owner_2.total_deductible_refunds.round(2)).to eq(0)
        expect(sticker_owner_2.pending_balance.round(2) - sticker_owner_2.total_pending_refunds.round(2)).to eq(0)
        expect(super_liker_1.available_balance.round(2) - super_liker_1.total_deductible_refunds.round(2)).to eq(0)
        expect(super_liker_1.pending_balance.round(2) - super_liker_1.total_pending_refunds.round(2)).to eq(0)
        expect(super_liker_2.available_balance.round(2) - super_liker_2.total_deductible_refunds.round(2)).to eq(0)
        expect(super_liker_2.pending_balance.round(2) - super_liker_2.total_pending_refunds.round(2)).to eq(0)
        expect(creator.available_balance.round(2) - creator.total_deductible_refunds.round(2)).to eq(0)
        expect(creator.pending_balance.round(2) - creator.total_pending_refunds.round(2)).to eq(0)
        expect(who_referred.available_balance.round(2) - who_referred.total_deductible_refunds.round(2)).to eq(0)
        expect(who_referred.pending_balance.round(2) - who_referred.total_pending_refunds.round(2)).to eq(0)

        UpdateBalanceJob.perform_now(
          [creator.id, sticker_owner.id, sticker_owner_2.id, user.id, who_referred.id,
           affiliate_owner.id, super_liker_1.id, super_liker_2.id]
        )
        creator.reload
        sticker_owner.reload
        sticker_owner_2.reload
        who_referred.reload
        affiliate_owner.reload
        super_liker_1.reload
        super_liker_2.reload

        expect(creator.cached_available_balance.to_f).to eq(0)
        expect(creator.cached_pending_balance.to_f).to eq(0)
        expect(sticker_owner.cached_available_balance.to_f).to eq(0)
        expect(sticker_owner.cached_pending_balance.to_f).to eq(0)
        expect(sticker_owner_2.cached_available_balance.to_f).to eq(0)
        expect(sticker_owner_2.cached_pending_balance.to_f).to eq(0)
        expect(super_liker_1.cached_available_balance.to_f).to eq(0)
        expect(super_liker_1.cached_pending_balance.to_f).to eq(0)
        expect(super_liker_2.cached_available_balance.to_f).to eq(0)
        expect(super_liker_2.cached_pending_balance.to_f).to eq(0)
        expect(who_referred.cached_available_balance.to_f).to eq(0)
        expect(who_referred.cached_pending_balance.to_f).to eq(0)
        expect(affiliate_owner.cached_available_balance.to_f).to eq(0)
        expect(affiliate_owner.cached_pending_balance.to_f).to eq(0)

        sticker_refund1 = StickerRefund.first
        sticker_refund1.amount_to_deduct = nil
        expect(sticker_refund1.creator_deduction(sticker_sale1, nil).round(2)).to eq(2.0)

        sticker_refund2 = StickerRefund.second
        sticker_refund2.amount_to_deduct = nil
        expect(sticker_refund2.creator_deduction(sticker_sale2, nil).round(2)).to eq(1.8)

        affiliate_refund = AffiliateRefund.first
        affiliate_refund.amount_to_deduct = nil
        expect(affiliate_refund.creator_deduction(affiliate_sale, nil).round(2)).to eq(1.8)

        referral_refund = ReferralRefund.first
        referral_refund.amount_to_deduct = nil
        expect(referral_refund.creator_deduction(referral_sale, nil).round(2)).to eq(1.13)

        refund = Refund.where(type: nil).first
        refund.amount_to_deduct = nil
        expect(refund.creator_deduction(sale, nil).round(2)).to eq(1.0)

        data_product_sale   = '1,39.99,14.0,25.99,23.0,2.99,100.0,2.99,1.0,3.8,1.8,0.0,All,0.0,0.0,0.0,0.0,0.0'
        data_sticker1_sale  = '1,18.0,0.0,18.0,0.0,18.0,11.0,2.0,2.0,0.0,0.0,0.0,All,0.0,0.0,0.0,0.0,0.0'
        data_sticker2_sale  = '1,18.0,0.0,18.0,0.0,18.0,10.0,1.8,1.8,0.0,0.0,0.0,All,0.0,0.0,0.0,0.0,0.0'
        data_affiliate_sale = '1,18.0,0.0,18.0,0.0,18.0,10.0,1.8,1.8,0.0,0.0,0.0,All,0.0,0.0,0.0,0.0,0.0'
        data_referral_sale  = '1,5.64,0.0,5.64,0.0,5.64,20.0,1.13,1.13,0.0,0.0,0.0,All,0.0,0.0,0.0,0.0,0.0'

        check_transactions_data(creator.api_token, data_product_sale, 'Product Sale')
        check_transactions_data(sticker_owner.api_token, data_sticker1_sale, 'Sticker Sale')
        check_transactions_data(sticker_owner_2.api_token, data_sticker2_sale, 'Sticker Sale')
        check_transactions_data(affiliate_owner.api_token, data_affiliate_sale, 'Affiliate Sale')
        check_transactions_data(who_referred.api_token, data_referral_sale, 'Referral Sale')
      end
    end

    describe 'ROC Order' do
      it 'successfully creates sale on order creation from shopify - ConnectSale, StickerSale, ConnectRefund, StickerRefund' do
        params = json_file_to_hash('webhooks_order_create_business_plan_connect')
        params['created_at'] = 20.days.ago

        creator.update(referrer_id: who_referred.id)
        SuperLike.create(product: product, user: super_liker_1)
        SuperLike.create(product: product, user: super_liker_2)
        product.update(
          shopify_product_id: '11876089478',
          variants_attributes: [
            { shopify_variant_id: '11115692422', size: 'Small', sku: 'ROCTS0001USM', price: '29.99' },
            { shopify_variant_id: '51264517126', size: 'XXX-Large', sku: 'ROCTS0001U3X', price: '39.99' }
          ],
          third_party_commission_type: 'fixed',
          third_party_commission_value: 1
        )
        mockup = product.build_mockup(
          id: 76,
          metadata: {
            version: '2',
            overlay: 'T-Shirts',
            processed_image: 'https://rageon-ios-faisal-dev.s3.amazonaws.com/F7AC5F6F-3C18-4FD0-8A26-6C9E480199B2-6.jpg',
            transform: '1.0,0.0,0.0,1.0,0.0,0.0',
            width: 414,
            height: 522.675,
            layers: [{
              type: 'image',
              src: 'https://rageon-ios-faisal-dev.s3.amazonaws.com/F7AC5F6F-3C18-4FD0-8A26-6C9E480199B2-4.jpg',
              transform: '1.0,0.0,0.0,1.0,0.333328247070312,0.0',
              height: 523,
              width: 641.6666666666666,
              x: 207,
              y: 261.3375
            }, {
              type: 'sticker',
              transform: '0.934475540391538,0.0,0.0,0.934475540391538,-22.3333206176758,-109.026180749207',
              stickerId: sticker1.id,
              height: 119.8067632850242,
              width: 266.6666666666667,
              x: 207,
              y: 261.3375
            }],
            small_image_width: 792,
            small_image_height: 1000
          },
          uuid: 'F7AC5F6F-3C18-4FD0-8A26-6C9E480199B2'
        )
        mockup.save

        Order.create(
          id: 10,
          shopify_order_id: '6472172358',
          status: 'new',
          created_at: Time.zone.now,
          updated_at: Time.zone.now,
          user: user,
          amount: 157.45,
          amount_charged: 157.45,
          stripe_charge_id: '123123123123',
          order_payload: {
            "total_price": 35.129999999999995,
            "total_tax": 0,
            "stripe_token": 'card_1ArWjLLRVA51AZiUKMc88zeU',
            "app_notes": "Order Number: #1078\nConnect Store: Connect Staging 12312\nConnect Shop: connect-staging.myshopify.com",
            "white_labeling_enabled": false,
            "third_party_app": ['RageOn Connect', 'Connect Staging 1231231231231231'],
            "billing_address": {
              "address1": '1392',
              "address2": '',
              "city": 'San Jose',
              "phone": '(000) 000-0000',
              "state": 'CA',
              "zip": '94109',
              "country": 'United States',
              "name": 'Faisal Ali',
              "first_name": 'Faisal',
              "last_name": 'Ali'
            },
            "shipping_address": {
              "first_name": 'Faisal',
              "last_name": 'Ali',
              "name": 'Faisal Ali',
              "address1": '2002 3rd St',
              "address2": '',
              "phone": '(832) 618-6945',
              "city": 'San Francisco',
              "province": 'California',
              "zip": '94107',
              "country": 'United States'
            },
            "line_items": [{
              "quantity": 5,
              "product_id": '11876089478',
              "variant_id": '51264517126',
              "item_cost": 30.58,
              "net_price": 21.490000000000002
            }],
            "shipping_line": {
              "price": 4.55,
              "title": 'Standard Shipping'
            },
            "tax_line": {
              "price": 0,
              "rate": 0,
              "title": 'None'
            }
          }
        )

        allow_any_instance_of(ShopifyWebhooksController).to receive(:verify_webhook).and_return(nil)

        post '/shopify_webhooks/order_create', params

        expect(response).to have_http_status(:success)
        expect(Sale.count).to eq(2)
        sale = ConnectSale.first
        expect(sale.unit_price).to eq(30.58)
        expect(sale.item_cost).to eq(29.58)
        expect(sale.order_id).to eq(10)
        expect(sale.commission_rate).to eq(1)
        expect(sale.quantity).to eq(5)
        expect(sale.profit).to eq(5)
        sale.profit = nil
        expect(sale.creator_take.round(2)).to eq(5)
        expect(StickerSale.count).to eq(1)
        sticker_sale = StickerSale.first
        expect(sticker_sale.unit_price).to eq(18.0)
        expect(sticker_sale.item_cost).to eq(0)
        expect(sticker_sale.order_id).to eq(10)
        expect(sticker_sale.commission_rate.round(2)).to eq(0.11)
        expect(sticker_sale.quantity).to eq(5)
        expect(sticker_sale.profit).to eq(10)
        sticker_sale.profit = nil
        expect(sticker_sale.creator_take.round(2)).to eq(10)

        expect(sale.user_id).to eq(creator.id)
        expect(creator.referrer).not_to eq(nil)
        expect(ReferralSale.count).to eq(0)
        expect(product.super_likes.count).to eq(2)
        expect(MicroSale.count).to eq(0)

        data_product_sale   = '5,224.95,72.05,152.9,147.9,5.0,100.0,5.0,0.0,0.0,0.0,5.0,All,0.0,0.0,0.0,0.0,0.0'
        data_sticker1_sale  = '5,90.0,0.0,90.0,0.0,90.0,11.0,10.0,0.0,0.0,0.0,10.0,All,0.0,0.0,0.0,0.0,0.0'

        check_transactions_data(creator.api_token, data_product_sale, 'Connect Sale')
        check_transactions_data(sticker_owner.api_token, data_sticker1_sale, 'Sticker Sale')

        params = json_file_to_hash('webhooks_refund_create_business_plan_connect')

        expect(Stripe::Refund).to receive(:create)
        allow_any_instance_of(ShopifyWebhooksController).to receive(:verify_webhook).and_return(nil)
        allow_any_instance_of(Net::HTTP).to receive(:request).and_return(true)

        post '/shopify_webhooks/refund_create', params

        expect(Refund.count).to eq(2)
        expect(StickerRefund.count).to eq(1)
        refund = Refund.first
        expect(refund.amount_to_deduct).to eq(5.0)
        refund.amount_to_deduct = nil
        expect(refund.creator_deduction(sale, 1.0).round(2)).to eq(5.0)
        refund = StickerRefund.first
        expect(refund.amount_to_deduct).to eq(10.0)
        refund.amount_to_deduct = nil
        expect(refund.creator_deduction(sticker_sale, 1.0).round(2)).to eq(10.0)

        data_product_sale   = '5,224.95,72.05,152.9,147.9,5.0,100.0,5.0,5.0,0.0,0.0,0.0,All,0.0,0.0,0.0,0.0,0.0'
        data_sticker1_sale  = '5,90.0,0.0,90.0,0.0,90.0,11.0,10.0,10.0,0.0,0.0,0.0,All,0.0,0.0,0.0,0.0,0.0'

        check_transactions_data(creator.api_token, data_product_sale, 'Connect Sale')
        check_transactions_data(sticker_owner.api_token, data_sticker1_sale, 'Sticker Sale')
      end
    end
  end
end
