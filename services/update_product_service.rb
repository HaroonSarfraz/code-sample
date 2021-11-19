class UpdateProductService
  attr_accessor :error

  def initialize(current_user, params)
    @params = params
    @current_user = current_user
  end

  def perform
    if update_params.key?(:title) && invalid_title?
      @error = CreateProductService::TITLE_ERROR_MSG
      return
    end

    product = @current_user.products.where(id: @params[:id]).first
    if product.present?
      shopify_updatable = false
      if update_params.key? :is_private
        is_private = update_params[:is_private].is_a?(String) ? (update_params[:is_private] == 'true' ? true : false) : update_params[:is_private]
        product.set_private(is_private) { false } # Added { false } to stop from calling update method
      elsif product.is_private.nil?
        product.set_private(false) { false }
      end

      if update_params.key? :title
        product.title = update_params[:title]
        shopify_updatable = true
      end
      if update_params.key? :description
        product.description = update_params[:description]
        shopify_updatable = true
      end

      if shopify_updatable
        begin
          s_product = ShopifyAPI::Product.find(product.shopify_product_id)
          s_product.title = product.title
          s_product.body_html = product.description

          if s_product.save
            product.save
          else
            @error = s_product.errors.messages.values.flatten.first
          end
        rescue => error
          Rails.logger.error error
          @error = 'Not able to edit product details on Shopify'
        end
      else
        product.save
      end
    else
      @error = 'Either product is not present or you do not have permission to edit this product.'
    end
  end

  private

  def invalid_title?
    @params[:title] && @params[:title].match(CreateProductService::TITLE_REGEX)
  end

  def update_params
    @update_params ||= begin
      @params.permit(
        :title,
        :description,
        :is_private
      )
    end
  end
end
