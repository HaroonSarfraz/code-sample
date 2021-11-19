# frozen_string_literal: true

# Public: Handle orders
class OrdersController < ApplicationController
  prepend_before_action :require_api_user, except: %i[find]
  prepend_before_action :require_printify_user, only: %i[create_printify get_printify update_printify delete_printify]

  FIND_WARNING = "We found your order, but shipping updates haven't been reported yet. If you need any help with your order, please contact us directly at info@rageon.com."

  def index
    customer = current_user.shopify_customer
    order_ids = current_user.orders.map(&:shopify_order_id).join(',')
    @orders = if order_ids.present?
                ShopifyAPI::Order.find(:all, params: { ids: order_ids })
              else
                []
              end
  end

  def find
    param = find_params
    render_error('Order Number & Email are required!') && return unless param[:order_name] || param[:email]
    order = Order.where('name = ? AND LOWER(email) = ?', param[:order_name], param[:email].downcase).first

    if order
      render_url(order.shopify_status_url) && return if order.shopify_status_url
      render_url(order.fulfillment_payload[0]['tracking_url']) && return if order.fulfillment_payload && order.fulfillment_payload[0] && order.fulfillment_payload[0]['tracking_url']
      render_warning(FIND_WARNING) && return
    else
      shopify_order = ShopifyAPI::Order.find(:all, params: { name: param[:order_name], email: param[:email] }).first
      if shopify_order && shopify_order.name == param[:order_name] && shopify_order.email == param[:email]
        order = Order.create_from_shopify_order(shopify_order)
        render_url(order.shopify_status_url) && return if order.shopify_status_url
        render_url(order.fulfillment_payload[0]['tracking_url']) && return if order.fulfillment_payload && order.fulfillment_payload[0] && order.fulfillment_payload[0]['tracking_url']
        render_warning(FIND_WARNING) && return
      end
    end

    render_error("Order number '#{param[:order_name]}' is not present in our system. Please contact our customer support at info@rageon.com") && return
  end

  def create
    response = CreateOrderFactory.get_service(current_user, order_params)
    if response.perform
      @order = response.order
    else
      render_error response.error
    end
  end

  # Printify controller stuff.

  def get_printify
    order_params = JSON.parse(request.params.to_json)
    printify_id = order_params.dig('printify_id')
    printify_order_service = PrintifyOrderService.new(order_params)

    if printify_order_service.perform_get
      @printify_order = printify_order_service.printify_order
      render json: { order: @printify_order }
    else
      render_printify_error printify_order_service.error
    end
  rescue StandardError => e
    render_printify_error e.message
  end

  def update_printify
    printify_order_service = get_printify_service
    if printify_order_service.perform_create_or_modify
      @printify_order = printify_order_service.printify_order
      render json: { status: 'success' }
    else
      render_printify_error printify_order_service.error
    end
  rescue StandardError => e
    puts "error #{e.message}"
    render_printify_error e.message
  end

  def delete_printify
    printify_order_service = get_printify_service
    if printify_order_service.perform_delete
      render json: {
        status: 'success',
        items: printify_order_service.printify_order['items'].map {|item| { id: item['id'], status: 'success' }
      } }
    else
      render_printify_error printify_order_service.error
    end
  rescue StandardError => e
    render_printify_error e.message
  end

  def create_printify
    order_params = JSON.parse(request.body.read)
    printify_order_service = PrintifyOrderService.new(order_params.dig('order') || order_params)

    if printify_order_service.perform_create_or_modify
      @printify_order = printify_order_service.printify_order
      render json: {
        status: 'success',
        id: printify_order_service.printify_id,
        reference_id: printify_order_service.s_order&.id
      }
    else
      render_printify_error printify_order_service.error
    end
  rescue StandardError => e
    render_printify_error e.message
  end

  def track_printify
    printify_order_service = get_printify_service
    if printify_order_service.perform_track && printify_order_service.order_status
      render json: {
        events: printify_order_service.tracking_events,
        status: printify_order_service.order_status
      }
    else
      render_printify_error printify_order_service.error
    end
  rescue StandardError => e
    render_printify_error e.message
  end

  def render_printify_error(error)
    render(
      json: { status: 'failed', errors: [error] },
      status: :unprocessable_entity
    )
  end

  private

  def get_printify_service

    request_params = JSON.parse(request.params.to_json)
    body_params = request.body&.read
    body_params = body_params.empty? ? {} : JSON.parse(body_params)
    order_params = body_params.empty? ? request_params : body_params
    order_params['printify_id'] = request_params&.dig('printify_id') || order_params.dig('printify_id')
    PrintifyOrderService.new(order_params)
  end

  def render_url(url)
    render json: { url: url }
  end

  def find_params
    params.permit(
      :order_name,
      :email
    )
  end

  def order_params
    params.permit(
      :total_price,
      :total_tax,
      paypal_confirmation: paypal_params,
      shipping_address: shipping_address_params,
      credit_card: %i[id number exp_month exp_year cvc],
      line_items: [%i[quantity product_id variant_id uuid]],
      shipping_line: %i[price title],
      tax_line: %i[price rate title]
    )
  end

  def paypal_params
    [
      :response_type,
      response: %i[intent id state create_time],
      client: %i[paypal_sdk_version environment platform product_name]
    ]
  end

  # Private: helper for order_params
  # returns array of permissible params to go within shipping address
  def shipping_address_params
    %i[
      first_name last_name
      address1
      address2
      city
      state
      province
      zip
      country
    ]
  end
end
