require 'rails_helper'

RSpec.describe ProductsController, type: :controller do
  render_views

  describe 'GET index' do
    it 'gets all products' do
      VCR.use_cassette('shopify_builder_products') do
        get :index, format: :json
      end

      expect(response).to have_http_status(:success)
      expect(assigns(:products).length).to be > 0
    end
  end

  describe 'GET restore' do
    it 'restores product' do
      product = FactoryBot.create(
        :product,
        visibility_settings: Product::VisibilitySettings.get_value(0, :unlisted),
        restore_token: '123123123'
      )

      expect(ShopifyToggleProductSellabilityJob).to receive(:perform_later)
      get :restore, token: '123123123'
      expect(response).to have_http_status(:redirect)
      product.reload
      expect(product.is_setting_enabled?(:unlisted)).to eq(false)
      expect(product.is_setting_enabled?(:sellable)).to eq(true)
    end

    it 'doesn\'t restore product' do
      product = FactoryBot.create(
        :product,
        visibility_settings: Product::VisibilitySettings.get_value(0, :unlisted),
        restore_token: '123',
        restored_at: Time.zone.now
      )

      expect(ShopifyToggleProductSellabilityJob).not_to receive(:perform_later)
      get :restore, token: '123123123'
      expect(response).to have_http_status(:success)
      product.reload
      expect(product.is_setting_enabled?(:unlisted)).to eq(true)
      expect(product.is_setting_enabled?(:sellable)).to eq(false)
    end

    it 'empty restore' do
      product = FactoryBot.create(
        :product,
        visibility_settings: Product::VisibilitySettings.get_value(0, :unlisted),
        restore_token: '123',
        restored_at: Time.zone.now
      )

      expect(ShopifyToggleProductSellabilityJob).not_to receive(:perform_later)
      get :restore, token: ''
      expect(response).to have_http_status(:success)
      product.reload
      expect(product.is_setting_enabled?(:unlisted)).to eq(true)
      expect(product.is_setting_enabled?(:sellable)).to eq(false)
    end

    it 'nil restore' do
      product = FactoryBot.create(
        :product,
        visibility_settings: Product::VisibilitySettings.get_value(0, :unlisted),
        restore_token: '123',
        restored_at: Time.zone.now
      )

      expect(ShopifyToggleProductSellabilityJob).not_to receive(:perform_later)
      get :restore
      expect(response).to have_http_status(:success)
      product.reload
      expect(product.is_setting_enabled?(:unlisted)).to eq(true)
      expect(product.is_setting_enabled?(:sellable)).to eq(false)
    end
  end

  describe 'GET show' do
    before(:each) do
      product = FactoryBot.create(:product, shopify_product_id: '1', shopify_product_handle: 'handle-here')
      FactoryBot.create(:variant, product: product, size: 'X-Small', style: 'Standard')
      FactoryBot.create(:variant, product: product, size: 'Small', style: 'Premium')
      FactoryBot.create(:variant, product: product, size: 'Medium', style: 'Ultra Premium')
      product_type = FactoryBot.create(
        :product_type,
        product: product,
        primary_image_asset_id: 10,
        name: 'Tank Tops',
        shopify_product_id: '2',
        shopify_product_handle: 'some-handle-here'
      )
      FactoryBot.create(:variant, shopify_product_id: product_type.shopify_product_id, size: 'X-Small', position: 1)
      FactoryBot.create(:variant, shopify_product_id: product_type.shopify_product_id, size: 'Small', position: 2)
      FactoryBot.create(:variant, shopify_product_id: product_type.shopify_product_id, size: 'Medium', position: 3)
    end
    it 'returns error when product is not found' do
      get :show, id: -100
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'returns json of a product by shopify_product_id' do
      get :show, id: Product.last.shopify_product_id
      expect(response).to have_http_status(:success)
      json = JSON.parse(response.body)

      expect(json['title']).to eq('Cool Design')
      expect(json['description']).to eq('it is very cool. look how cool it is.')
      expect(json['typeName']).to eq('T-Shirts')

      expect(json['options'].count).to eq(3)
      expect(json['options'].first['key']).to eq('size')
      expect(json['options'].first['values'].count).to eq(9)
      expect(json['options'].second['key']).to eq('printedSides')
      expect(json['options'].second['values'].count).to eq(2)
      expect(json['options'].third['key']).to eq('handSewn')
      expect(json['options'].third['values'].count).to eq(2)

      expect(json['variants'].count).to eq(3)
      expect(json['variants'].first['size']).to eq('XS')
      expect(json['variants'].first['printedSides']).to eq('single')
      expect(json['variants'].first['handSewn']).to eq(false)

      expect(json['variants'].second['size']).to eq('S')
      expect(json['variants'].second['printedSides']).to eq('double')
      expect(json['variants'].second['handSewn']).to eq(false)

      expect(json['variants'].third['size']).to eq('M')
      expect(json['variants'].third['printedSides']).to eq('double')
      expect(json['variants'].third['handSewn']).to eq(true)

      expect(json['relatedItems'].count).to eq 1
      expect(json['relatedItems'].first['key']).to eq('same-design')
      expect(json['relatedItems'].first['items'].count).to eq(1)
      expect(json['relatedItems'].first['items'].first['assetId']).to eq(10)
      expect(json['relatedItems'].first['items'].first['name']).to eq('Tank Tops')
      expect(json['productSpecs']).not_to be nil

      Product.last.update(description: nil)
      get :show, id: Product.last.shopify_product_id
      expect(response).to have_http_status(:success)
      json = JSON.parse(response.body)

      expect(json['title']).to eq('Cool Design')
      expect(json['description']).to eq('RageOn is the best place online to shop for T-Shirts! Browse our T-Shirts and find amazing custom designs from your favorite artists and brands.')
    end

    it 'returns json of a product by shopify_product_handle' do
      get :show, id: Product.last.shopify_product_handle
      expect(response).to have_http_status(:success)
      json = JSON.parse(response.body)

      expect(json['title']).to eq('Cool Design')
      expect(json['description']).to eq('it is very cool. look how cool it is.')
      expect(json['typeName']).to eq('T-Shirts')

      expect(json['options'].count).to eq(3)
      expect(json['options'].first['key']).to eq('size')
      expect(json['options'].first['values'].count).to eq(9)
      expect(json['options'].second['key']).to eq('printedSides')
      expect(json['options'].second['values'].count).to eq(2)
      expect(json['options'].third['key']).to eq('handSewn')
      expect(json['options'].third['values'].count).to eq(2)

      expect(json['variants'].count).to eq(3)
      expect(json['variants'].first['size']).to eq('XS')
      expect(json['variants'].first['printedSides']).to eq('single')
      expect(json['variants'].first['handSewn']).to eq(false)

      expect(json['variants'].second['size']).to eq('S')
      expect(json['variants'].second['printedSides']).to eq('double')
      expect(json['variants'].second['handSewn']).to eq(false)

      expect(json['variants'].third['size']).to eq('M')
      expect(json['variants'].third['printedSides']).to eq('double')
      expect(json['variants'].third['handSewn']).to eq(true)

      expect(json['relatedItems'].count).to eq 1
      expect(json['relatedItems'].first['key']).to eq('same-design')
      expect(json['relatedItems'].first['items'].count).to eq(1)
      expect(json['relatedItems'].first['items'].first['assetId']).to eq(10)
      expect(json['relatedItems'].first['items'].first['name']).to eq('Tank Tops')
      expect(json['productSpecs']).not_to be nil

      Product.last.update(description: nil)
      get :show, id: Product.last.shopify_product_handle

      expect(response).to have_http_status(:success)
      json = JSON.parse(response.body)

      expect(json['title']).to eq('Cool Design')
      expect(json['description']).to eq('RageOn is the best place online to shop for T-Shirts! Browse our T-Shirts and find amazing custom designs from your favorite artists and brands.')
    end

    it 'returns json of a product type' do
      Product.last.update(description: nil)
      get :show, id: ProductType.last.shopify_product_id
      expect(response).to have_http_status(:success)
      json = JSON.parse(response.body)

      expect(json['title']).to eq('Cool Design')
      expect(json['typeName']).to eq('Tank Tops')
      expect(json['description']).to eq('RageOn is the best place online to shop for Tank Tops! Browse our Tank Tops and find amazing custom designs from your favorite artists and brands.')

      expect(json['options'].count).to eq(1)
      expect(json['options'].first['key']).to eq('size')
      expect(json['options'].first['values'].count).to eq(9)

      expect(json['variants'].count).to eq(3)
      expect(json['variants'].first['size']).to eq('XS')
      expect(json['variants'].first['printedSides']).to eq(nil)
      expect(json['variants'].first['handSewn']).to eq(nil)
      expect(json['variants'].second['size']).to eq('S')
      expect(json['variants'].third['size']).to eq('M')

      expect(json['productSpecs']).not_to be nil

      expect(json['relatedItems'].count).to eq 0
    end
  end

  describe 'GET measurements' do
    it 'gets measurement of custom list of product types' do
      get :measurements, product_types: ['T-Shirts', 'Women T-Shirts', 'Tank Tops']
      json = JSON.parse(response.body)
      3.times do |i|
        expect(json[i]['title']).not_to eq(nil)
        expect(json[i]['html']).not_to eq(nil)
      end
    end
    it 'gets measurement of default list of product types' do
      get :measurements
      json = JSON.parse(response.body)
      24.times do |i|
        expect(json[i]['title']).not_to eq(nil)
        expect(json[i]['html']).not_to eq(nil)
      end
    end
  end


end
