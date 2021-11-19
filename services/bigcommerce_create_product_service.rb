class BigcommerceCreateProductService
  attr_accessor :product, :response_body, :errors, :image_asset_id

  VARIANT_OPTIONS = %i[size color quality].freeze
  PRODUCT_CREATE_URL = "/stores/#{ENV['BC_STORE_HASH']}/v3/catalog/products".freeze

  CATEGORIES = Bigcommerce::Category.all(limit: 200).map{|a| [a.name, a.id] }.to_h

  def initialize(product_id)
    @product = Product.find product_id

    @image_asset_id = product.primary_image_asset_id
    unless image_asset_id
      shopify_product = ShopifyAPI::Product.find(product.shopify_product_id)
      @image_asset_id = shopify_product&.metafields&.find{|a| a.key == 'mockup_asset_id'}&.value
    end
  end

  def perform
    return unless product

    min_price_variant = product.variants.min_by(&:price)
    request_body = {
      name: product.title,
      description: product.description || '',
      price: min_price_variant.price,
      retail_price: min_price_variant.compare_at_price,
      weight: min_price_variant.weight,
      categories: [fetch_or_create_category_id],
      variants: product_variants_data,
      type: 'physical',
      availability: 'available',
      is_visible: true,
      inventory_tracking: product.is_rts? ? 'variant' : 'none',
      images: product_images
    }

    send_request(request_body)
    response_body ? product.update(bigcommerce_product_id: response_body['id']) : false
  end

  private

  def product_images
    images = [{
      image_url: ROShared.image_url(image_asset_id),
      is_thumbnail: true,
      sort_order: 0
    }]

    product.mockups.order(:mockup_type).each.with_index do |mockup, index|
      next if mockup.mockup_asset_id == product.primary_image_asset_id

      images << {
        image_url: ROShared.image_url(mockup.mockup_asset_id),
        sort_order: index + 1
      }
    end

    images
  end

  def send_request(request_body)
    counter = 0
    loop do
      begin
        res = Bigcommerce::System.raw_request(
          :post, PRODUCT_CREATE_URL,
          counter.positive? ? request_body.merge({ name: "#{request_body[:name]} #{counter}" }) : request_body
        )

        if res.success?
          @response_body = JSON.parse(res.body)['data']
        else
          Rails.logger.error "Result: failure | #{res.code} | #{req_path}"
          @errors = res
        end

        return
      rescue StandardError => e
        counter += 1
        next if e.as_json.try(:dig, 'response_headers', 'title') == 'The product name is a duplicate' && counter < 10

        Rails.logger.error "Failed: #{e}"
        @errors = e && return
      end
    end
  end

  def fetch_or_create_category_id
    category_id = CATEGORIES[product.product_type]
    unless category_id
      category = Bigcommerce::Category.create(name: product.product_type)
      CATEGORIES[category.name] = category.id
    end
    category_id || category.id
  end

  def product_variants_data
    product.variants.map do |variant|
      {
        sku: "#{variant.sku} #{variant.id}",
        price: variant.price,
        retail_price: variant.compare_at_price,
        inventory_level: product.is_rts? ? 10 : 0,
        image_url: ROShared.image_url(variant.primary_image_asset_id || image_asset_id),
        option_values: variant_option_values(variant)
      }
    end
  end

  def variant_option_values(variant)
    VARIANT_OPTIONS.map do |option|
      value = variant.public_send(option)
      value ? { option_display_name: option.to_s, label: value } : nil
    end.compact
  end
end
